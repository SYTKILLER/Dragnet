//go:build windows

// dragnet-tun 是罗网 Dragnet 的 Windows CLI（M1 MVP，前身 P0-W PoC）。
//
// 链路：sing-tun(gVisor) 全局路由捕获 → tunstack.Handler 流级判决 →
//   - DNS（UDP 53）劫持：域名匹配 → 命中阻断回 NXDOMAIN；放行转发上游并
//     把应答 A/AAAA 写入 IP↔域名有界缓存；
//   - TCP：缓存域名 / SNI·HTTP Host 嗅探 → 匹配 → 阻断(RST)或绑定物理网卡中继；
//   - 其他 UDP：缓存域名匹配 → 阻断或中继。
//
// 进程识别：TUN 捕获的包未经 NAT，源端点即进程 socket 本地端点，
// 用 GetExtendedTcp/UdpTable 反查 PID（internal/procid），记录不参与规则。
// 处理链本体在 internal/tunstack（与 Android 内核共用）。
//
// 运行需管理员（建 TUN + 改路由）。出站全部绑定物理网卡（IP_UNICAST_IF），
// 避免 AutoRoute 0.0.0.0/0 造成的回环。编译：go build -tags with_gvisor ./cmd/dragnet-tun
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"syscall"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	"golang.org/x/sys/windows"

	"github.com/SYTKILLER/Dragnet/internal/blocklist"
	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/procid"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/tunstack"
	"github.com/SYTKILLER/Dragnet/internal/windns"
)

func main() {
	lists := flag.String("lists", "build/rules", "规则目录（.txt），缺目录时仅用内置种子")
	inet4 := flag.String("inet4", "172.19.0.1/30", "TUN IPv4 地址/掩码")
	mtu := flag.Uint("mtu", 1500, "TUN MTU")
	tunName := flag.String("tun-name", "Dragnet", "TUN 适配器名")
	ifaceName := flag.String("iface", "", "出站绑定的物理网卡名；缺省自动取默认路由网卡（TUN 建立前判定）")
	dnsUp := flag.String("dns", "223.5.5.5:53", "上游 DNS")
	dnsTimeout := flag.Duration("dns-timeout", 3*time.Second, "上游 DNS 超时")
	noDNSTakeover := flag.Bool("no-dns-takeover", false, "禁用 DNS 接管（诊断用；毒化应答可旁路）")
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

	procs := procid.NewCache()
	flushDNSCache(la)
	h := tunstack.New(tunstack.Config{
		Holder:     &holder,
		Cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		DNSUp:      upAddr,
		DNSTimeout: *dnsTimeout,
		Bind:       bind,
		ProcessLookup: func(network uint8, source netip.AddrPort) string {
			if network == 6 { // TCP
				return procs.LookupTCP(source)
			}
			return procs.LookupUDP(source)
		},
		Log: la,
	})

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

	// DNS 接管（多 DNS 竞速根因修复，round5 疑点）：把所有带 DNS 的物理适配器
	// 指向 TUN 内置 DNS，消除"查询旁路直奔物理网卡 DNS"的竞速窗口。退出时还原。
	var dnsSaved []windns.Snapshot
	if *noDNSTakeover {
		la.Warn("已按 -no-dns-takeover 跳过 DNS 接管（仅供诊断，毒化应答可旁路拦截）")
	} else {
		tunDNS, err := options.Inet4DNSAddress()
		if err == nil && len(tunDNS) > 0 {
			dnsSaved = takeoverDNS(tunDNS[0], *tunName, la)
			_ = windnsFlush() // 接管后立即清缓存，旧毒化记录全部失效
		}
	}

	// 周期运行统计（M1 长稳验证用）。
	done := make(chan struct{})
	go func() {
		start := time.Now()
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				s := h.Snapshot()
				log.Printf("运行统计: up=%s dns(阻断%d/转发%d) tcp(阻断%d/中继%d) udp(阻断%d/中继%d) 缓存%d条",
					time.Since(start).Round(time.Second),
					s.DNSBlocked, s.DNSForwarded, s.TCPBlocked, s.TCPRelayed,
					s.UDPBlocked, s.UDPRelayed, s.CacheLen)
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
	if len(dnsSaved) > 0 {
		restoreDNS(dnsSaved, la)
		_ = windnsFlush()
	}
	_ = ifaceMon.Close()
	_ = netMon.Close()
	log.Printf("已清理（TUN 适配器、WFP 规则与系统 DNS 随进程结束还原）")
}

// takeoverDNS 快照并接管所有带 DNS 的物理适配器（指向 tunDNS）。
// 逐适配器容错：单个失败只告警，其余继续。
func takeoverDNS(tunDNS netip.Addr, tunName string, la *logAdapter) []windns.Snapshot {
	saved, err := windns.SnapshotAdapters(tunName)
	if err != nil {
		la.Warn("DNS 快照失败，跳过接管: ", err)
		return nil
	}
	var applied []windns.Snapshot
	for _, s := range saved {
		g := s.GUID
		if err := windns.SetDNS(&g, windows.AF_INET, []netip.Addr{tunDNS}); err != nil {
			la.Warn("接管 ", s.Name, " IPv4 DNS 失败: ", err)
			continue
		}
		if err := windns.SetDNS(&g, windows.AF_INET6, nil); err != nil {
			la.Warn("接管 ", s.Name, " IPv6 DNS 失败（v4 已接管）: ", err)
		}
		applied = append(applied, s)
	}
	if len(applied) > 0 {
		log.Printf("DNS 已接管: %d 个适配器 → %s（退出时还原原配置）", len(applied), tunDNS)
	} else {
		la.Warn("没有适配器被接管（无已配置 DNS 的物理适配器？）")
	}
	return applied
}

// restoreDNS 把快照的原始 DNS 配置写回各适配器。
func restoreDNS(saved []windns.Snapshot, la *logAdapter) {
	for _, s := range saved {
		g := s.GUID
		if err := windns.SetDNS(&g, windows.AF_INET, s.V4); err != nil {
			la.Warn("还原 ", s.Name, " IPv4 DNS 失败: ", err)
		}
		if err := windns.SetDNS(&g, windows.AF_INET6, s.V6); err != nil {
			la.Warn("还原 ", s.Name, " IPv6 DNS 失败: ", err)
		}
	}
	log.Printf("系统 DNS 已还原（%d 个适配器）", len(saved))
}

func windnsFlush() error {
	return windns.FlushResolverCache()
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

// flushDNSCache 启动时清空 Windows DNS 客户端缓存：此前解析过的广告域名
// 会留在系统缓存里（含 ISP 毒化应答），TUN 上线后应用/nslookup 直接命中缓存、
// 查询包根本不进内核，DNS 级拦截被绕过（测试机 P0-W round4 实测定位）。
// SNI 嗅探仍兜底 TLS 连接，但缓存清理是必要卫生。
func flushDNSCache(la *logAdapter) {
	ret, _, err := windows.NewLazySystemDLL("dnsapi.dll").NewProc("DnsFlushResolverCache").Call()
	if ret != 0 {
		log.Printf("已刷新系统 DNS 缓存（防旧缓存绕过 DNS 级拦截）")
	} else {
		la.Warn("刷新系统 DNS 缓存失败: ", err)
	}
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
