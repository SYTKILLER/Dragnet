//go:build windows

// dragnet-tun 是罗网 Dragnet 的 Windows TUN+进程识别 PoC（P0-W）。
//
// 链路：sing-tun(gVisor) 全局路由捕获 → JudgeFlow 流级判决 →
//   - DNS（UDP 53）劫持：域名匹配 → 命中阻断回 NXDOMAIN；放行转发上游并
//     把应答 A/AAAA 写入 IP↔域名有界缓存；
//   - TCP：缓存域名 / SNI·HTTP Host 嗅探 → 匹配 → 阻断(RST)或绑定物理网卡中继；
//   - 其他 UDP：缓存域名匹配 → 阻断或中继。
//
// 进程识别：TUN 捕获的包未经 NAT，源端点即进程 socket 本地端点，
// 用 GetExtendedTcp/UdpTable 反查 PID（internal/procid），PoC 仅记录不参与规则。
//
// 运行需管理员（建 TUN + 改路由）。出站全部绑定物理网卡（IP_UNICAST_IF），
// 避免 AutoRoute 0.0.0.0/0 造成的回环。编译：go build -tags with_gvisor ./cmd/dragnet-tun
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/control"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/windows"

	"github.com/SYTKILLER/Dragnet/internal/blocklist"
	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/procid"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/sniff"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

const (
	protoICMP uint8 = 1
	protoTCP  uint8 = 6
	protoUDP  uint8 = 17
)

func main() {
	lists := flag.String("lists", "build/rules", "规则目录（.txt）")
	inet4 := flag.String("inet4", "172.19.0.1/30", "TUN IPv4 地址/掩码")
	mtu := flag.Uint("mtu", 1500, "TUN MTU")
	tunName := flag.String("tun-name", "Dragnet", "TUN 适配器名")
	ifaceName := flag.String("iface", "", "出站绑定的物理网卡名；缺省自动取默认路由网卡（TUN 建立前判定）")
	dnsUp := flag.String("dns", "223.5.5.5:53", "上游 DNS")
	dnsTimeout := flag.Duration("dns-timeout", 3*time.Second, "上游 DNS 超时")
	verbose := flag.Bool("v", false, "打印 sing-tun 内部调试日志")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	la := newLogAdapter(*verbose)

	// 规则：内置种子（开箱即用）+ 可选外部订阅目录（缺目录仅告警不失败）。
	named := []engine.NamedRules{{Name: blocklist.StarterName, Text: blocklist.Starter()}}
	if srcs, err := rules.SourcesFromDir(*lists); err == nil {
		for _, s := range srcs {
			if b, err := os.ReadFile(s.Path); err == nil {
				named = append(named, engine.NamedRules{Name: s.Name, Text: string(b)})
			} else {
				la.Warn("跳过规则文件 ", s.Path, ": ", err)
			}
		}
	} else {
		la.Warn("外部订阅目录不可用（", err, "），仅使用内置种子规则")
	}
	var holder rules.Holder
	must(holder.LoadRules(named), "加载规则")
	st := holder.Current().Stats()
	log.Printf("规则引擎就绪: 内置种子 %d 条 + %d 个订阅, 共 %d 行, 存储≈%.1fMB",
		blocklist.Lines(), st.Lists-1, st.RuleLines, float64(st.StorageEstBytes)/1e6)

	upAddr, err := netip.ParseAddrPort(*dnsUp)
	must(err, "解析 -dns")

	// 网络监视器 + 接口查找器（sing-tun AutoRoute 依赖）。
	netMon, err := tun.NewNetworkUpdateMonitor(la)
	must(err, "创建网络监视器")
	finder := control.NewDefaultInterfaceFinder()
	ifaceMon, err := tun.NewDefaultInterfaceMonitor(netMon, la, tun.DefaultInterfaceMonitorOptions{InterfaceFinder: finder})
	must(err, "创建接口监视器")
	must(netMon.Start(), "启动网络监视器")
	must(ifaceMon.Start(), "启动接口监视器")

	// 出站绑定接口必须在 TUN 抢占默认路由之前确定。
	bindIndex, err := pickBindIndex(*ifaceName, upAddr.Addr())
	must(err, "确定出站网卡")
	bind := control.BindToInterface(finder, "", bindIndex)
	log.Printf("出站绑定: %s", describeInterface(bindIndex))

	h := &handler{
		holder:     &holder,
		cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		proc:       procid.NewCache(),
		dialer:     &net.Dialer{Timeout: 10 * time.Second, Control: bind},
		listenCfg:  net.ListenConfig{Control: bind},
		dnsUp:      upAddr,
		dnsTimeout: *dnsTimeout,
		log:        la,
	}

	prefix := netip.MustParsePrefix(*inet4)
	options := tun.Options{
		Name:             *tunName,
		Inet4Address:     []netip.Prefix{prefix},
		MTU:              uint32(*mtu),
		AutoRoute:        true,
		StrictRoute:      true, // WFP 屏蔽其他网卡的明文 53 出口，防 DNS 旁路；随进程退出自动撤销
		InterfaceMonitor: ifaceMon,
		InterfaceFinder:  finder,
		Logger:           la,
	}

	dev, err := tun.New(options)
	must(err, "创建 TUN（需管理员权限）")
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    context.Background(),
		Tun:        dev,
		TunOptions: options,
		Handler:    h,
		Logger:     la,
		UDPTimeout: 5 * time.Minute,
	})
	must(err, "创建 gVisor 栈（需 -tags with_gvisor 编译）")

	must(dev.Start(), "启动 TUN（配置地址/DNS/路由）")
	must(stack.Start(), "启动栈")
	log.Printf("罗网 TUN 上线: %s, MTU %d, 全局路由已接管；Ctrl+C 退出并自动清理", prefix, *mtu)

	// 周期运行统计（M1 长稳验证用）。
	done := make(chan struct{})
	go func() {
		start := time.Now()
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				log.Printf("运行统计: up=%s dns(阻断%d/转发%d) tcp(阻断%d/中继%d) udp(阻断%d/中继%d) 缓存%d条",
					time.Since(start).Round(time.Second),
					h.dnsBlocked.Load(), h.dnsForwarded.Load(),
					h.tcpBlocked.Load(), h.tcpRelayed.Load(),
					h.udpBlocked.Load(), h.udpRelayed.Load(),
					h.cache.Len())
			case <-done:
				return
			}
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig

	close(done)
	log.Printf("正在退出…")
	_ = stack.Close()
	_ = dev.Close()
	_ = ifaceMon.Close()
	_ = netMon.Close()
	log.Printf("已清理（TUN 适配器与 WFP 规则随进程结束移除）")
}

// pickBindIndex 选出站物理网卡：显式 -iface 优先；否则在 TUN 建立前用
// GetBestInterfaceEx 对上游 DNS 求最优路由接口（此刻默认路由仍指向物理网卡）。
func pickBindIndex(name string, probe netip.Addr) (int, error) {
	if name != "" {
		nif, err := net.InterfaceByName(name)
		if err != nil {
			return 0, fmt.Errorf("找不到网卡 %s: %w", name, err)
		}
		return nif.Index, nil
	}
	var idx uint32
	sa := &windows.SockaddrInet4{Port: 53}
	sa.Addr = probe.As4()
	if err := windows.GetBestInterfaceEx(sa, &idx); err != nil {
		return 0, fmt.Errorf("GetBestInterfaceEx(%s): %w（可改用 -iface 显式指定）", probe, err)
	}
	return int(idx), nil
}

func describeInterface(index int) string {
	if nif, err := net.InterfaceByIndex(index); err == nil {
		return fmt.Sprintf("%s (index %d)", nif.Name, index)
	}
	return fmt.Sprintf("index %d", index)
}

// ---- sing-tun Handler 实现 ----

type handler struct {
	holder     *rules.Holder
	cache      *ipcache.Cache
	proc       *procid.Cache
	dialer     *net.Dialer
	listenCfg  net.ListenConfig
	dnsUp      netip.AddrPort
	dnsTimeout time.Duration
	log        *logAdapter

	// 运行统计（长稳验证）。
	dnsBlocked   atomic.Uint64
	dnsForwarded atomic.Uint64
	tcpBlocked   atomic.Uint64
	tcpRelayed   atomic.Uint64
	udpBlocked   atomic.Uint64
	udpRelayed   atomic.Uint64
}

// recoverFlow 是 M1 长稳的 panic 边界：任何回调 panic 只断当前流，
// 不允许击穿 sing-tun 回调线程拖垮整个进程。
func (h *handler) recoverFlow(what string, src, dst any) {
	if r := recover(); r != nil {
		h.log.Error("panic(", what, " ", src, " -> ", dst, "): ", r, "（已隔离，进程继续）")
	}
}

// JudgeFlow 在流建立时同步调用（TCP 首包前 / 每 UDP 会话首包，firstPacket
// 仅 UDP 提供 payload），必须快速返回。
func (h *handler) JudgeFlow(network uint8, source, destination netip.AddrPort, firstPacket []byte) tun.FlowVerdict {
	if network == protoUDP && destination.Port() == 53 && len(firstPacket) > 0 {
		return tun.FlowVerdict{Action: tun.ActionHijackDNS}
	}
	domain := h.cache.Domain(destination.Addr(), time.Now())
	if domain != "" {
		res := h.match(domain, destination, h.processName(network, source))
		if res.Action == verdict.ActionBlock {
			h.log.Info("阻断 ", networkName(network), " ", source, " -> ", destination,
				" domain=", domain, " ", ruleInfo(res))
			return tun.FlowVerdict{Action: tun.ActionReject}
		}
	}
	return tun.FlowVerdict{Action: tun.ActionAccept}
}

// NewDNSPacket 处理被劫持的 DNS 查询。转发循环内同步调用，必须异步处理。
func (h *handler) NewDNSPacket(payload []byte, source, destination M.Socksaddr, writer N.PacketWriter) {
	go h.handleDNS(payload, destination, writer)
}

func (h *handler) handleDNS(payload []byte, destination M.Socksaddr, writer N.PacketWriter) {
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
		h.log.Warn("DNS 解析失败: ", err)
		return
	}
	if query.Response || len(query.Questions) == 0 {
		return // 只处理查询
	}
	qname := strings.TrimSuffix(strings.ToLower(query.Questions[0].Name.String()), ".")

	res := h.match(qname, destination.AddrPort(), "")
	if res.Action == verdict.ActionBlock {
		h.dnsBlocked.Add(1)
		h.log.Info("阻断 DNS ", qname, " ", ruleInfo(res))
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
	h.dnsForwarded.Add(1)

	respPayload, err := h.exchange(query.ID, payload)
	if err != nil {
		h.log.Warn("上游 DNS 失败 ", qname, ": ", err)
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
				h.cache.Put(netip.AddrFrom4(body.A), qname, now)
			case *dnsmessage.AAAAResource:
				h.cache.Put(netip.AddrFrom16(body.AAAA), qname, now)
			}
		}
	}
	write(respPayload)
}

// exchange 向上游转发原始查询报文并等待应答（绑定物理网卡出站）。
func (h *handler) exchange(queryID uint16, payload []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), h.dnsTimeout+time.Second)
	defer cancel()
	pc, err := h.listenCfg.ListenPacket(ctx, "udp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	defer pc.Close()
	_ = pc.SetDeadline(time.Now().Add(h.dnsTimeout))

	remote := &net.UDPAddr{IP: h.dnsUp.Addr().AsSlice(), Port: int(h.dnsUp.Port())}
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
// 命中阻断则直接断开，否则绑定物理网卡中继。
func (h *handler) NewConnectionEx(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer h.recoverFlow("tcp", source, destination)
	if onClose != nil {
		defer onClose(nil)
	}
	defer conn.Close()

	proc := h.proc.LookupTCP(source.AddrPort())
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
			h.cache.Put(destination.AddrPort().Addr(), domain, time.Now())
		}
	}

	res := h.match(domain, destination.AddrPort(), proc)
	if res.Action == verdict.ActionBlock {
		h.tcpBlocked.Add(1)
		h.log.Info("阻断 TCP ", source, " -> ", destination,
			" domain=", orNone(domain), " process=", orNone(proc), " ", ruleInfo(res))
		return
	}
	h.tcpRelayed.Add(1)
	if domain == "" {
		h.log.Info("中继 TCP ", source, " -> ", destination, " （无域名证据）")
	} else {
		h.log.Info("中继 TCP ", source, " -> ", destination, " domain=", domain)
	}

	remote, err := h.dialer.DialContext(ctx, "tcp", destination.AddrPort().String())
	if err != nil {
		h.log.Warn("出站拨号失败 ", destination, ": ", err)
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
func (h *handler) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	defer h.recoverFlow("udp", source, destination)
	if onClose != nil {
		defer onClose(nil)
	}
	defer conn.Close()

	res := h.match(h.cache.Domain(destination.AddrPort().Addr(), time.Now()), destination.AddrPort(), h.proc.LookupUDP(source.AddrPort()))
	if res.Action == verdict.ActionBlock {
		h.udpBlocked.Add(1)
		h.log.Info("阻断 UDP ", source, " -> ", destination, " ", ruleInfo(res))
		return
	}
	h.udpRelayed.Add(1)

	pc, err := h.listenCfg.ListenPacket(ctx, "udp", "0.0.0.0:0")
	if err != nil {
		h.log.Warn("UDP 出站套接字失败: ", err)
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
	<-done
}

// ---- 内部助手 ----

func (h *handler) match(domain string, destination netip.AddrPort, process string) verdict.Result {
	return h.holder.Match(&engine.Request{
		Domain:      domain,
		DomainBasis: verdict.BasisDNS,
		IP:          destination.Addr(),
		Port:        destination.Port(),
		Process:     process,
	})
}

func (h *handler) processName(network uint8, source netip.AddrPort) string {
	if network == protoTCP {
		return h.proc.LookupTCP(source)
	}
	return h.proc.LookupUDP(source)
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

// relay 双向拷贝直到任一方结束。
func relay(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(a, b); done <- struct{}{} }()
	go func() { io.Copy(b, a); done <- struct{}{} }()
	<-done
	<-done
}

func must(err error, what string) {
	if err != nil {
		log.Fatalf("%s: %v", what, err)
	}
}

// ---- sing logger 适配 ----

type logAdapter struct{ verbose bool }

func newLogAdapter(verbose bool) *logAdapter { return &logAdapter{verbose: verbose} }

func (l *logAdapter) Trace(args ...any) {
	if l.verbose {
		log.Println(append([]any{"[TRACE]"}, args...)...)
	}
}
func (l *logAdapter) Debug(args ...any) {
	if l.verbose {
		log.Println(append([]any{"[DEBUG]"}, args...)...)
	}
}
func (l *logAdapter) Info(args ...any)  { log.Println(args...) }
func (l *logAdapter) Warn(args ...any)  { log.Println("[WARN]", fmt.Sprint(args...)) }
func (l *logAdapter) Error(args ...any) { log.Println("[ERROR]", fmt.Sprint(args...)) }
func (l *logAdapter) Fatal(args ...any) { log.Fatalf("%s", fmt.Sprint(args...)) }
func (l *logAdapter) Panic(args ...any) { log.Panicf("%s", fmt.Sprint(args...)) }
