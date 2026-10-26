//go:build windows

package wincore

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"os"
	"path/filepath"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	"golang.org/x/sys/windows"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipc"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/procid"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/subscribe"
	"github.com/SYTKILLER/Dragnet/internal/tunstack"
	"github.com/SYTKILLER/Dragnet/internal/verify"
	"github.com/SYTKILLER/Dragnet/internal/windns"
)

// DefaultDNSTimeout 是上游 DNS 的默认超时。
const DefaultDNSTimeout = 3 * time.Second

// CoreOptions 是内核装配的全部入参（控制台 flag 与服务配置共用）。
type CoreOptions struct {
	Lists      string // 规则目录
	Inet4      string // TUN 地址/掩码
	MTU        uint32
	TunName    string
	IfaceName  string // 出站绑定网卡名；空=自动
	DNSUp      netip.AddrPort
	DNSTimeout time.Duration

	SubscribeConfig string
	NoDNSTakeover   bool
	NoIPC           bool
}

// Run 装配并运行内核直到 ctx 取消；返回前的清理保证系统状态还原。
func Run(ctx context.Context, opts CoreOptions, la *LogAdapter) error {
	// 规则目录是唯一规则来源（M4-R1 规则可见性合规：种子/订阅/白名单均为
	// 外部可见文件，无任何内嵌规则）。目录缺失或为空时空载运行（fail-open：
	// Holder 无引擎时 Match 恒 NoMatch 放行），显式 WARN 不静默。
	// 加载链（M4-R2/R3）：构建 → 样本断言 → 原子切换；失败回滚 last-known-good；
	// 成功后快照 LKG 供下次回滚。
	var holder rules.Holder
	loadDir := func(dir string) ([]engine.NamedRules, error) {
		srcs, err := rules.SourcesFromDir(dir)
		if err != nil {
			return nil, err
		}
		named := make([]engine.NamedRules, 0, len(srcs))
		for _, s := range srcs {
			b, err := os.ReadFile(s.Path)
			if err != nil {
				la.Warn("跳过规则文件 ", s.Path, ": ", err)
				continue
			}
			named = append(named, engine.NamedRules{Name: s.Name, Text: string(b)})
		}
		return named, nil
	}
	samplesPath := filepath.Join(opts.Lists, "verify-samples.list")
	lkgDir := filepath.Join(opts.Lists, ".lkg")
	applyRules := func() error {
		named, err := loadDir(opts.Lists)
		if err != nil {
			return err
		}
		var vfy func(engine.Matcher) error
		if samples, serr := verify.LoadSamples(samplesPath); serr == nil {
			vfy = func(m engine.Matcher) error {
				if fails := verify.Check(m, samples); len(fails) > 0 {
					return fmt.Errorf("验证样本 %d/%d 不过，例如 %s (期望 %s 得到 %s)",
						len(fails), len(samples), fails[0].Sample.Domain,
						fails[0].Sample.Want, fails[0].Got)
				}
				return nil
			}
		}
		if err := holder.LoadVerified(named, vfy); err != nil {
			// M4-R3：样本不过/构建失败 → 回退 last-known-good。
			la.Warn("规则加载未通过（", err, "），尝试 last-known-good 回滚")
			lkgNamed, lerr := loadDir(lkgDir)
			if lerr != nil || len(lkgNamed) == 0 {
				return fmt.Errorf("LKG 回滚不可用: %w", err)
			}
			if lerr := holder.LoadRules(lkgNamed); lerr != nil {
				return fmt.Errorf("LKG 回滚失败: %w（沿用旧引擎）", lerr)
			}
			la.Warn("已回滚到 last-known-good 规则（降级运行）")
			return nil
		}
		// 成功：快照当前规则为 LKG（.lkg 子目录，SourcesFromDir 不会读子目录）。
		snapshotLKG(opts.Lists, lkgDir, la)
		return nil
	}
	var reloadAll = applyRules
	if err := applyRules(); err != nil {
		la.Error("规则加载失败且无 LKG 可回滚——空载运行：无任何规则生效（fail-open）: ", err)
	} else if cur := holder.Current(); cur != nil {
		st := cur.Stats()
		log.Printf("规则引擎就绪: %d 个规则文件, 共 %d 行, 存储≈%.1fMB",
			st.Lists, st.RuleLines, float64(st.StorageEstBytes)/1e6)
	} else {
		la.Warn("规则目录为空——空载运行：无任何规则生效（fail-open）")
	}

	// 网络监视器 + 接口查找器（sing-tun AutoRoute 依赖）。
	netMon, err := tun.NewNetworkUpdateMonitor(la)
	if err != nil {
		return fmt.Errorf("创建网络监视器: %w", err)
	}
	finder := control.NewDefaultInterfaceFinder()
	ifaceMon, err := tun.NewDefaultInterfaceMonitor(netMon, la, tun.DefaultInterfaceMonitorOptions{InterfaceFinder: finder})
	if err != nil {
		return fmt.Errorf("创建接口监视器: %w", err)
	}
	if err := netMon.Start(); err != nil {
		return fmt.Errorf("启动网络监视器: %w", err)
	}
	if err := ifaceMon.Start(); err != nil {
		return fmt.Errorf("启动接口监视器: %w", err)
	}

	// 出站绑定接口必须在 TUN 抢占默认路由之前确定。
	bindIndex, err := pickBindIndex(opts.IfaceName, opts.DNSUp.Addr())
	if err != nil {
		return fmt.Errorf("确定出站网卡: %w", err)
	}
	bind := control.BindToInterface(finder, "", bindIndex)
	log.Printf("出站绑定: %s", describeInterface(bindIndex))

	ring := newBlockRing(256)
	procs := procid.NewCache()
	flushDNSCache(la)
	h := tunstack.New(tunstack.Config{
		Holder:     &holder,
		Cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		DNSUp:      opts.DNSUp,
		DNSTimeout: opts.DNSTimeout,
		Bind:       bind,
		ProcessLookup: func(network uint8, source netip.AddrPort) string {
			if network == 6 { // TCP
				return procs.LookupTCP(source)
			}
			return procs.LookupUDP(source)
		},
		OnBlocked: func(kind, domain, rule, list, process string, dest netip.AddrPort) {
			ring.add(ipc.BlockEvent{Time: time.Now(), Kind: kind, Domain: domain,
				Rule: rule, List: list, Process: process, Dest: dest.String()})
		},
		Log: la,
	})

	prefix, err := netip.ParsePrefix(opts.Inet4)
	if err != nil {
		return fmt.Errorf("解析 TUN 地址: %w", err)
	}
	options := tun.Options{
		Name:             opts.TunName,
		Inet4Address:     []netip.Prefix{prefix},
		MTU:              opts.MTU,
		AutoRoute:        true,
		StrictRoute:      true, // WFP 屏蔽其他网卡的明文 53 出口，防 DNS 旁路；随进程退出自动撤销
		InterfaceMonitor: ifaceMon,
		InterfaceFinder:  finder,
		Logger:           la,
	}

	dev, err := tun.New(options)
	if err != nil {
		return fmt.Errorf("创建 TUN（需管理员权限）: %w", err)
	}
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    ctx,
		Tun:        dev,
		TunOptions: options,
		Handler:    h,
		Logger:     la,
		UDPTimeout: 5 * time.Minute,
	})
	if err != nil {
		return fmt.Errorf("创建 gVisor 栈（需 -tags with_gvisor 编译）: %w", err)
	}

	if err := dev.Start(); err != nil {
		return fmt.Errorf("启动 TUN（配置地址/DNS/路由）: %w", err)
	}
	if err := stack.Start(); err != nil {
		return fmt.Errorf("启动栈: %w", err)
	}
	log.Printf("罗网 TUN 上线: %s, MTU %d, 全局路由已接管", prefix, opts.MTU)

	// DNS 接管（多 DNS 竞速根因修复）：物理适配器 DNS → TUN 内置 DNS，退出还原。
	var dnsSaved []windns.Snapshot
	if opts.NoDNSTakeover {
		la.Warn("已按 no-dns-takeover 跳过 DNS 接管（仅供诊断，毒化应答可旁路拦截）")
	} else {
		if tunDNS, err := options.Inet4DNSAddress(); err == nil && len(tunDNS) > 0 {
			dnsSaved = takeoverDNS(tunDNS[0], opts.TunName, la)
			_ = windns.FlushResolverCache() // 接管后立即清缓存，旧毒化记录全部失效
		}
	}

	// 本机控制管道（M3 控制面：状态/回溯/白名单热切换）。
	if !opts.NoIPC {
		ctl := &ctlHandler{start: time.Now(), ring: ring, listsDir: opts.Lists,
			reload: reloadAll, log: la.Warn}
		if srv, err := ipc.NewServer(ctl, false); err == nil {
			go func() {
				if err := srv.Serve(); err != nil {
					la.Error("IPC 服务退出: ", err)
				}
			}()
			log.Printf("控制管道就绪: %s（白名单变更即热切换）", ipc.PipeName)
		} else {
			la.Warn("IPC 服务初始化失败: ", err)
		}
	}

	// 后台订阅刷新（M3 条件更新）：出站 HTTP 也绑定物理网卡，避免经 TUN 绕一圈。
	if opts.SubscribeConfig != "" {
		if cfg, err := subscribe.LoadConfig(opts.SubscribeConfig); err != nil {
			la.Warn("订阅配置无效，后台刷新停用: ", err)
		} else {
			mgr := subscribe.NewManager(opts.Lists, cfg, reloadAll, la)
			mgr.SetClient(&http.Client{
				Timeout:   60 * time.Second,
				Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, DialContext: (&net.Dialer{Timeout: 30 * time.Second, Control: bind}).DialContext},
			})
			go mgr.Run()
			log.Printf("后台订阅刷新已启用: %d 源, 间隔 %s", len(cfg.Sources), mgr.Interval())
		}
	}

	// 周期运行统计（长稳验证用）。
	statDone := make(chan struct{})
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
			case <-statDone:
				return
			}
		}
	}()

	<-ctx.Done()
	close(statDone)
	log.Printf("正在退出…")
	_ = stack.Close()
	_ = dev.Close()
	if len(dnsSaved) > 0 {
		restoreDNS(dnsSaved, la)
		_ = windns.FlushResolverCache()
	}
	_ = ifaceMon.Close()
	_ = netMon.Close()
	return nil
}

// takeoverDNS 快照并接管所有带 DNS 的物理适配器（指向 tunDNS）。
// 逐适配器容错：单个失败只告警，其余继续。
func takeoverDNS(tunDNS netip.Addr, tunName string, la *LogAdapter) []windns.Snapshot {
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
func restoreDNS(saved []windns.Snapshot, la *LogAdapter) {
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

func flushDNSCache(la *LogAdapter) {
	ret, _, err := windows.NewLazySystemDLL("dnsapi.dll").NewProc("DnsFlushResolverCache").Call()
	if ret != 0 {
		log.Printf("已刷新系统 DNS 缓存（防旧缓存绕过 DNS 级拦截）")
	} else {
		la.Warn("刷新系统 DNS 缓存失败: ", err)
	}
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

// snapshotLKG 把规则目录的全部顶层 .txt 复制到 lkgDir（成功加载后的快照，
// M4-R3 回滚数据源）。规则目录里放 .lkg 子目录不会参与加载（SourcesFromDir
// 不递归）。逐文件容错：个别失败只告警。
func snapshotLKG(listsDir, lkgDir string, la *LogAdapter) {
	if err := os.MkdirAll(lkgDir, 0o755); err != nil {
		la.Warn("创建 LKG 目录失败: ", err)
		return
	}
	entries, err := os.ReadDir(listsDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".txt") {
			continue
		}
		src := filepath.Join(listsDir, e.Name())
		dst := filepath.Join(lkgDir, e.Name())
		b, err := os.ReadFile(src)
		if err != nil {
			continue
		}
		if err := os.WriteFile(dst, b, 0o644); err != nil {
			la.Warn("LKG 快照 ", e.Name(), " 失败: ", err)
		}
	}
}
