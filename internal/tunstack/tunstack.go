// Package tunstack 是罗网内核的平台无关 TUN 处理链：sing-tun Handler 的
// 全部回调（流级判决 / DNS 劫持 / TCP 中继 / UDP 中继）+ 域名证据管线 +
// 统计与 panic 边界。平台差异只体现在两处注入点：
//
//   - Config.Bind：出站套接字绑定。Windows=IP_UNICAST_IF 绑物理网卡；
//     Android=VpnService.protect(fd)（JNI 回调）；二者都为防回环。
//   - Config.ProcessLookup：进程识别。Windows=iphlpapi 反查；Android 暂无。
//
// Windows CLI（cmd/dragnet-tun）与 Android 内核（cmd/dragnetvpn）共用本包，
// 保证两端拦截语义一致（M2「同一核心」要求）。
package tunstack

import (
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/control"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/net/dns/dnsmessage"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/sniff"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

const (
	protoICMP uint8 = 1
	protoTCP  uint8 = 6
	protoUDP  uint8 = 17
)

// Config 是处理链的注入点集合。
type Config struct {
	Holder     *rules.Holder
	Cache      *ipcache.Cache
	DNSUp      netip.AddrPort
	DNSTimeout time.Duration

	// Bind 出站套接字控制（防回环），可为 nil（测试环境）。
	Bind control.Func
	// ProcessLookup 进程识别注入，可为 nil。
	ProcessLookup func(network uint8, source netip.AddrPort) string
	// Log 使用 sing logger 接口（与 sing-tun 同一适配器复用）。
	Log Logger
}

// Logger 是本包日志依赖的最小接口（sing logger.Logger 的子集）。
type Logger interface {
	Debug(args ...any)
	Info(args ...any)
	Warn(args ...any)
	Error(args ...any)
}

// Stats 是运行统计快照（长稳验证）。
type Stats struct {
	DNSBlocked, DNSForwarded uint64
	TCPBlocked, TCPRelayed   uint64
	UDPBlocked, UDPRelayed   uint64
	CacheLen                 int
}

// Handler 实现 tun.Handler。
type Handler struct {
	cfg   Config
	stats statsCounters
}

type statsCounters struct {
	dnsBlocked, dnsForwarded atomic.Uint64
	tcpBlocked, tcpRelayed   atomic.Uint64
	udpBlocked, udpRelayed   atomic.Uint64
}

// New 构建处理链。
func New(cfg Config) *Handler {
	return &Handler{cfg: cfg}
}

// Snapshot 返回统计快照。
func (h *Handler) Snapshot() Stats {
	return Stats{
		DNSBlocked:   h.stats.dnsBlocked.Load(),
		DNSForwarded: h.stats.dnsForwarded.Load(),
		TCPBlocked:   h.stats.tcpBlocked.Load(),
		TCPRelayed:   h.stats.tcpRelayed.Load(),
		UDPBlocked:   h.stats.udpBlocked.Load(),
		UDPRelayed:   h.stats.udpRelayed.Load(),
		CacheLen:     h.cfg.Cache.Len(),
	}
}

// recoverFlow 是长稳的 panic 边界：任何回调 panic 只断当前流，
// 不允许击穿 sing-tun 回调线程拖垮整个进程。
func (h *Handler) recoverFlow(what string, src, dst any) {
	if r := recover(); r != nil {
		h.cfg.Log.Error("panic(", what, " ", src, " -> ", dst, "): ", r, "（已隔离，进程继续）")
	}
}

// JudgeFlow 在流建立时同步调用（TCP 首包前 / 每 UDP 会话首包，firstPacket
// 仅 UDP 提供 payload），必须快速返回。
func (h *Handler) JudgeFlow(network uint8, source, destination netip.AddrPort, firstPacket []byte) tun.FlowVerdict {
	if network == protoUDP && destination.Port() == 53 && len(firstPacket) > 0 {
		return tun.FlowVerdict{Action: tun.ActionHijackDNS}
	}
	domain := h.cfg.Cache.Domain(destination.Addr(), time.Now())
	if domain != "" {
		res := h.match(domain, destination, h.processName(network, source))
		if res.Action == verdict.ActionBlock {
			h.cfg.Log.Info("阻断 ", networkName(network), " ", source, " -> ", destination,
				" domain=", domain, " ", ruleInfo(res))
			return tun.FlowVerdict{Action: tun.ActionReject}
		}
	}
	return tun.FlowVerdict{Action: tun.ActionAccept}
}

// NewDNSPacket 处理被劫持的 DNS 查询。转发循环内同步调用，必须异步处理。
//
// 注意：payload 是 sing-tun/gVisor 内部包缓冲的视图（stack_gvisor_udp.go 的
// view.AsSlice），回调返回后栈即回收并复用该内存。异步处理前必须同步拷贝，
// 否则 goroutine 读到被覆写的数据——表现为随机"DNS 解析失败"、误判转发
// （测试机 P0-W round1/2 实测：阻断域名被放行，上游毒化应答被中继）。
func (h *Handler) NewDNSPacket(payload []byte, source, destination M.Socksaddr, writer N.PacketWriter) {
	data := make([]byte, len(payload))
	copy(data, payload)
	go h.handleDNS(data, source, destination, writer)
}

func (h *Handler) handleDNS(payload []byte, source, destination M.Socksaddr, writer N.PacketWriter) {
	defer h.recoverFlow("dns", "-", destination)

	write := func(data []byte) {
		b := buf.NewSize(len(data))
		if _, err := b.Write(data); err != nil {
			b.Release()
			return
		}
		// writer 自行释放 buffer；destination 即原查询目的地址（伪装 DNS 服务器）。
		_ = writer.WritePacket(b, destination)
	}

	var query dnsmessage.Message
	if err := query.Unpack(payload); err != nil {
		// 拷贝修复后仍出现的解析失败即真实畸形报文，留头部十六进制定位来源。
		n := min(len(payload), 48)
		h.cfg.Log.Warn("DNS 解析失败: ", err, " src=", source, " dst=", destination,
			" len=", len(payload), " head=", hex.EncodeToString(payload[:n]))
		return
	}
	if query.Response || len(query.Questions) == 0 {
		return // 只处理查询
	}
	qname := strings.TrimSuffix(strings.ToLower(query.Questions[0].Name.String()), ".")

	res := h.match(qname, destination.AddrPort(), "")
	h.cfg.Log.Debug("DNS 判定 qname=", qname, " action=", res.Action, " list=", res.List, " dst=", destination)
	if res.Action == verdict.ActionBlock {
		h.stats.dnsBlocked.Add(1)
		h.cfg.Log.Info("阻断 DNS ", qname, " ", ruleInfo(res))
		resp := dnsmessage.Message{
			ID:                 query.ID,
			Response:           true,
			OpCode:             query.OpCode,
			RecursionDesired:   query.RecursionDesired,
			RecursionAvailable: true,
			RCode:              dnsmessage.RCodeNameError,
			Questions:          query.Questions,
		}
		if packed, err := resp.Pack(); err == nil {
			write(packed)
		}
		return
	}
	h.stats.dnsForwarded.Add(1)

	respPayload, err := h.exchange(query.ID, payload)
	if err != nil {
		h.cfg.Log.Warn("上游 DNS 失败 ", qname, ": ", err)
		resp := dnsmessage.Message{
			ID:               query.ID,
			Response:         true,
			RecursionDesired: query.RecursionDesired,
			RCode:            dnsmessage.RCodeServerFailure,
			Questions:        query.Questions,
		}
		if packed, err := resp.Pack(); err == nil {
			write(packed)
		}
		return
	}

	// 把上游应答中的 A/AAAA 写入 IP→域名缓存（弱证据，SNI 可覆盖）。
	var answers dnsmessage.Message
	if err := answers.Unpack(respPayload); err == nil {
		now := time.Now()
		for _, rr := range answers.Answers {
			switch body := rr.Body.(type) {
			case *dnsmessage.AResource:
				h.cfg.Cache.Put(netip.AddrFrom4(body.A), qname, now)
			case *dnsmessage.AAAAResource:
				h.cfg.Cache.Put(netip.AddrFrom16(body.AAAA), qname, now)
			}
		}
	}
	write(respPayload)
}

// exchange 向上游转发原始查询报文并等待应答（出站走 Config.Bind 绑定）。
func (h *Handler) exchange(queryID uint16, payload []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), h.cfg.DNSTimeout+time.Second)
	defer cancel()
	lc := net.ListenConfig{Control: h.cfg.Bind}
	pc, err := lc.ListenPacket(ctx, "udp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	defer pc.Close()
	_ = pc.SetDeadline(time.Now().Add(h.cfg.DNSTimeout))

	remote := &net.UDPAddr{IP: h.cfg.DNSUp.Addr().AsSlice(), Port: int(h.cfg.DNSUp.Port())}
	if _, err := pc.WriteTo(payload, remote); err != nil {
		return nil, err
	}
	rbuf := make([]byte, 4096)
	for range 3 { // 最多容忍 2 个错包/晚到的应答
		n, _, err := pc.ReadFrom(rbuf)
		if err != nil {
			return nil, err
		}
		if n >= 12 && binaryID(rbuf[:n]) == queryID {
			return rbuf[:n], nil
		}
	}
	return nil, fmt.Errorf("上游应答不匹配")
}

func binaryID(b []byte) uint16 { return uint16(b[0])<<8 | uint16(b[1]) }

// NewConnectionEx 处理 TCP：先嗅探 SNI/HTTP Host（无缓存证据时的强证据），
// 命中阻断则直接断开，否则绑定出站中继。
func (h *Handler) NewConnectionEx(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer h.recoverFlow("tcp", source, destination)
	if onClose != nil {
		defer onClose(nil)
	}
	defer conn.Close()

	proc := ""
	if h.cfg.ProcessLookup != nil {
		proc = h.cfg.ProcessLookup(protoTCP, source.AddrPort())
	}
	domain := ""
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var first [4096]byte
	n, rerr := conn.Read(first[:])
	conn.SetReadDeadline(time.Time{})
	if rerr == nil && n > 0 {
		domain = sniff.TLSClientHelloSNI(first[:n])
		if domain == "" {
			domain = sniff.HTTPHost(first[:n])
		}
		if domain != "" {
			// SNI/Host 是连接级直接观测，覆盖 DNS 反查的弱证据。
			h.cfg.Cache.Put(destination.AddrPort().Addr(), domain, time.Now())
		}
	}

	res := h.match(domain, destination.AddrPort(), proc)
	if res.Action == verdict.ActionBlock {
		h.stats.tcpBlocked.Add(1)
		h.cfg.Log.Info("阻断 TCP ", source, " -> ", destination,
			" domain=", orNone(domain), " process=", orNone(proc), " ", ruleInfo(res))
		return
	}
	h.stats.tcpRelayed.Add(1)
	if domain == "" {
		h.cfg.Log.Info("中继 TCP ", source, " -> ", destination, " （无域名证据）")
	} else {
		h.cfg.Log.Info("中继 TCP ", source, " -> ", destination, " domain=", domain)
	}

	dialer := net.Dialer{Timeout: 10 * time.Second, Control: h.cfg.Bind}
	remote, err := dialer.DialContext(ctx, "tcp", destination.AddrPort().String())
	if err != nil {
		h.cfg.Log.Warn("出站拨号失败 ", destination, ": ", err)
		return
	}
	defer remote.Close()
	if n > 0 {
		if _, err := remote.Write(first[:n]); err != nil {
			return
		}
	}
	relay(conn, remote)
}

// NewPacketConnectionEx 中继非 DNS 的 UDP 会话（如 QUIC）：域名证据只能
// 来自缓存；无证据按 fail-open 放行。
func (h *Handler) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer h.recoverFlow("udp", source, destination)
	if onClose != nil {
		defer onClose(nil)
	}
	defer conn.Close()

	var proc string
	if h.cfg.ProcessLookup != nil {
		proc = h.cfg.ProcessLookup(protoUDP, source.AddrPort())
	}
	res := h.match(h.cfg.Cache.Domain(destination.AddrPort().Addr(), time.Now()), destination.AddrPort(), proc)
	if res.Action == verdict.ActionBlock {
		h.stats.udpBlocked.Add(1)
		h.cfg.Log.Info("阻断 UDP ", source, " -> ", destination, " ", ruleInfo(res))
		return
	}
	h.stats.udpRelayed.Add(1)

	lc := net.ListenConfig{Control: h.cfg.Bind}
	pc, err := lc.ListenPacket(ctx, "udp", "0.0.0.0:0")
	if err != nil {
		h.cfg.Log.Warn("UDP 出站套接字失败: ", err)
		return
	}
	defer pc.Close()
	remote := net.UDPAddrFromAddrPort(destination.AddrPort())

	done := make(chan struct{}, 2)
	go func() { // 客户端 → 服务器
		defer func() { done <- struct{}{} }()
		for {
			b := buf.NewSize(65535)
			dest, err := conn.ReadPacket(b)
			if err != nil {
				b.Release()
				return
			}
			target := remote
			if d := dest.UDPAddr(); d != nil {
				target = d
			}
			_, err = pc.WriteTo(b.Bytes(), target)
			b.Release()
			if err != nil {
				return
			}
		}
	}()
	go func() { // 服务器 → 客户端
		defer func() { done <- struct{}{} }()
		for {
			rbuf := make([]byte, 65535)
			n, _, err := pc.ReadFrom(rbuf)
			if err != nil {
				return
			}
			b := buf.NewSize(n)
			if _, err := b.Write(rbuf[:n]); err != nil {
				b.Release()
				return
			}
			if err := conn.WritePacket(b, destination); err != nil {
				return
			}
		}
	}()
	<-done
	// 任一方向终结即会话已死：立即关闭两端套接字解除另一方向的阻塞。
	// 此前等待双方自然结束——服务器静默+客户端已亡时 pc.ReadFrom 永久阻塞，
	// 每条会话泄漏 socket+2 goroutine+64KB 缓冲（测试机 round1 实测 5 分钟
	// 工作集涨到 3.4GB，UDP 中继约 7200 条/分钟）。
	pc.Close()
	conn.Close()
	<-done
}

// ---- 内部助手 ----

func (h *Handler) match(domain string, destination netip.AddrPort, process string) verdict.Result {
	return h.cfg.Holder.Match(&engine.Request{
		Domain:      domain,
		DomainBasis: verdict.BasisDNS,
		IP:          destination.Addr(),
		Port:        destination.Port(),
		Process:     process,
	})
}

func (h *Handler) processName(network uint8, source netip.AddrPort) string {
	if h.cfg.ProcessLookup == nil {
		return ""
	}
	return h.cfg.ProcessLookup(network, source)
}

func ruleInfo(res verdict.Result) string {
	if res.Action != verdict.ActionBlock {
		return "action=" + res.Action.String()
	}
	s := "rule=" + res.RuleText
	if res.List != "" {
		s += " list=" + res.List
	}
	return s
}

func networkName(n uint8) string {
	switch n {
	case protoTCP:
		return "TCP"
	case protoUDP:
		return "UDP"
	case protoICMP:
		return "ICMP"
	default:
		return fmt.Sprintf("proto%d", n)
	}
}

func orNone(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// relayDrainTimeout 是客户端发完后的半关闭宽限：等待服务器剩余应答的上限，
// 超时即强制关闭，防止静默对端把会话与 goroutine 永久挂住。
const relayDrainTimeout = 30 * time.Second

// relay 双向拷贝（a=客户端侧 gVisor 连接，b=出站真实连接）。
// 服务器方向先结束视为事务完成，立即关双端；客户端方向先结束则半关闭出站
// （FIN 但保留读），宽限期内收完剩余应答，超时强制回收——此前无限等待双方
// 结束，静默对端会造成与 UDP 同类的会话滞留。
func relay(a, b net.Conn) {
	s2c := make(chan struct{}) // b → a
	c2s := make(chan struct{}) // a → b
	go func() { defer close(s2c); io.Copy(a, b) }()
	go func() { defer close(c2s); io.Copy(b, a) }()
	select {
	case <-s2c:
	case <-c2s:
		if cw, ok := b.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
		select {
		case <-s2c:
		case <-time.After(relayDrainTimeout):
		}
	}
	a.Close()
	b.Close()
	<-s2c
	<-c2s
}
