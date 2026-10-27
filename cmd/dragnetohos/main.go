//go:build ohos && cgo

// dragnetohos 把罗网完整内核（TUN 处理链 + 规则引擎）暴露为 HarmonyOS 动态库，
// 同时是 NAPI 模块本体（github.com/likuai2010/ohos-napi，MIT；ClashBox 同源）。
// 平台薄壳（ArkTS VpnExtensionAbility）只做四件事：create 拿 tun fd、注册
// protect 回调、加载规则目录、起停内核——拦截语义全部在本库
// （与 Windows CLI / Android 共用 internal/tunstack，三端语义一致）。
//
// 构建脚本：scripts/build-ohos.sh；产物 build/ohos/<abi>/libdragnet.so，
// 壳工程 ohos/entry 直接 import（详见 ohos/README.md）。
//
// NAPI 导出（import dragnet from 'libdragnet.so'）：
//
//	startVpn(tunFd, dnsUp, mtu, protectCb): Promise<number>
//	stopVpn(): number
//	setProtected(id): void
//	loadRules(dir): number
//	stats(): string（未运行返回 ""）
//	match(domain): string（JSON：{action, rule, list}）
//
// 出站防回环——protect 回握协议（与 ClashBox 同型，ClashBox 实测 JS 事件循环
// 被系统限流时 protect IPC 往返可能超 500ms）：
//
//	内核 socket 建立前 → 分配递增 id、注册等待 channel → tsfn 通知 JS(id, fd)
//	→ JS 调 VpnConnection.protect(fd) 后回调 setProtected(id) → 内核放行 connect。
//	5s 超时按拨号失败处理（未保护的出站流量会回环进 TUN，宁可该会话失败）。
//
// ABI 契约（基线 docs/tech/03 §6，与 dragnetvpn 一致）：
//   - 线程模型：NAPI 回调在 JS 线程；内核状态由互斥锁与原子序号保护；
//     tsfn 调用可来自任意内核 goroutine。
//   - 内存所有权：出参字符串按值返回（NAPI 拷贝），无跨边界指针所有权。
//   - 崩溃边界：全部导出 recover panic，返回负数错误码（Promise 拒绝值）。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	tun "github.com/sagernet/sing-tun"

	napi "github.com/likuai2010/ohos-napi"
	"github.com/likuai2010/ohos-napi/entry"
	"github.com/likuai2010/ohos-napi/js"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/tunstack"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// 与 ohos/entry VpnExtAbility.ets 中 VpnConfig 保持一致。
const (
	tunAddr    = "10.111.222.1/24" // VpnConfig.addresses
	tunDNSAddr = "10.111.222.3"    // VpnConfig.dnsAddresses（进入 TUN 后被劫持）
	dnsTimeout = 3 * time.Second
)

var (
	holderMu sync.Mutex
	holder   rules.Holder

	runMu    sync.Mutex
	runStack tun.Stack
	runDev   tun.Tun
	runStart time.Time
	runStats *tunstack.Handler

	// protect 回握状态
	protectTsfn atomic.Pointer[js.TsFunc] // nil 表示未注册（protect 直接放行；atomic：注册在 JS 线程、消费在内核 goroutine）
	protectSeq  atomic.Int64
	protectWait sync.Map // id -> chan struct{}
)

// ---- NAPI 导出 ----

// startVpn 启动内核：tunFd 来自 VpnConnection.create()；protectCb(id, fd)
// 由 JS 侧实现（调 VpnConnection.protect(fd) 后 setProtected(id) 回握）。
// 异步执行，resolve 0 成功 / 负数错误码。
func startVpn(env js.Env, this js.Value, args []js.Value) any {
	defer recoverExport(env)
	tunFd, _ := napi.GetValueInt32(env.Env, args[0].Value)
	dnsUp, _ := napi.GetValueStringUtf8(env.Env, args[1].Value)
	mtu, _ := napi.GetValueInt32(env.Env, args[2].Value)

	// 先注册 protect 回调（进入内核 goroutine 前完成，避免竞态）
	tsfn := env.CreateThreadsafeFunction(args[3], "dragnetProtect")
	protectTsfn.Store(&tsfn)

	promise := env.NewPromise()
	go func() {
		promise.Resolve(startVPN(int(tunFd), dnsUp, int(mtu)))
	}()
	return promise
}

// stopVpn 停止内核并释放 TUN。
func stopVpn(env js.Env, this js.Value, args []js.Value) any {
	defer recoverExport(env)
	return stopVPN()
}

// setProtected JS 侧 protect 完成后的回握：唤醒等待 connect 的内核 goroutine。
func setProtected(env js.Env, this js.Value, args []js.Value) any {
	id, _ := napi.GetValueInt32(env.Env, args[0].Value)
	if ch, ok := protectWait.Load(int64(id)); ok {
		select {
		case ch.(chan struct{}) <- struct{}{}:
		default:
		}
	}
	return nil
}

// loadRules 从目录加载外部规则（filesDir/rules/*.txt），0 成功。
// 须在 startVpn 之前调用；加载失败保留原引擎（空载 fail-open）。
func loadRules(env js.Env, this js.Value, args []js.Value) any {
	defer recoverExport(env)
	dir, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	if dir == "" {
		return -1
	}
	srcs, err := rules.SourcesFromDir(dir)
	if err != nil {
		return -2
	}
	holderMu.Lock()
	defer holderMu.Unlock()
	if err := holder.Load(srcs); err != nil {
		return -3
	}
	return 0
}

// stats 返回运行统计 JSON 字符串（未运行返回 ""）。
func stats(env js.Env, this js.Value, args []js.Value) any {
	runMu.Lock()
	h := runStats
	start := runStart
	runMu.Unlock()
	if h == nil {
		return ""
	}
	s := h.Snapshot()
	// 数字字段手动拼装，避免引入全量 JSON 体积（与 dragnetvpn 一致）
	out := fmt.Sprintf(
		`{"uptime_sec":%d,"dns_blocked":%d,"dns_forwarded":%d,"tcp_blocked":%d,"tcp_relayed":%d,"udp_blocked":%d,"udp_relayed":%d,"cache":%d}`,
		int(time.Since(start).Seconds()),
		s.DNSBlocked, s.DNSForwarded, s.TCPBlocked, s.TCPRelayed, s.UDPBlocked, s.UDPRelayed, s.CacheLen)
	return out
}

// match 按域名查询当前引擎（无网络副作用，供壳内自检/排障）。
// 返回 JSON：{"action":..,"rule":..,"list":..}。
func match(env js.Env, this js.Value, args []js.Value) any {
	domain, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	if domain == "" {
		return ""
	}
	holderMu.Lock()
	h := holder
	holderMu.Unlock()
	res := h.Match(&engine.Request{Domain: domain, DomainBasis: verdict.BasisDNS})
	b, _ := json.Marshal(map[string]any{
		"action": res.Action.String(),
		"rule":   res.RuleText,
		"list":   res.List,
	})
	return string(b)
}

func init() {
	entry.Export("startVpn", js.AsCallback(startVpn))
	entry.Export("stopVpn", js.AsCallback(stopVpn))
	entry.Export("setProtected", js.AsCallback(setProtected))
	entry.Export("loadRules", js.AsCallback(loadRules))
	entry.Export("stats", js.AsCallback(stats))
	entry.Export("match", js.AsCallback(match))
}

// ---- 内核起停 ----

func startVPN(fd int, dnsUp string, mtu int) (rc int) {
	defer func() {
		if r := recover(); r != nil {
			_ = r
			rc = -99
		}
	}()
	runMu.Lock()
	defer runMu.Unlock()
	if runStack != nil {
		return -10 // 已在运行
	}
	up, err := netip.ParseAddrPort(dnsUp)
	if err != nil {
		return -11
	}
	if fd <= 0 {
		return -12
	}
	if mtu <= 0 {
		mtu = 1500
	}

	// 规则仅来自外部加载（M4-R1 规则可见性合规——无任何内嵌种子）。
	olog := &ohosLogger{}
	holderMu.Lock()
	if holder.Current() == nil {
		olog.Warn("无外部规则（filesDir/rules 为空）——空载运行：无任何规则生效（fail-open）")
	}
	holderLocal := &holder
	holderMu.Unlock()

	h := tunstack.New(tunstack.Config{
		Holder:     holderLocal,
		Cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		DNSUp:      up,
		DNSTimeout: dnsTimeout,
		Bind:       protectBind,
		Log:        olog,
	})

	prefix := netip.MustParsePrefix(tunAddr)
	options := tun.Options{
		// 路由与地址由 VpnConfig 配置，内核只消费 fd。
		FileDescriptor: fd,
		MTU:            uint32(mtu),
		Inet4Address:   []netip.Prefix{prefix},
		Logger:         olog,
	}
	dev, err := tun.New(options)
	if err != nil {
		return -14
	}
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    context.Background(),
		Tun:        dev,
		TunOptions: options,
		Handler:    h,
		Logger:     olog,
		UDPTimeout: 5 * time.Minute,
	})
	if err != nil {
		return -15
	}
	if err := dev.Start(); err != nil {
		return -16
	}
	if err := stack.Start(); err != nil {
		return -17
	}
	runDev, runStack, runStats = dev, stack, h
	runStart = time.Now()
	olog.Info("罗网内核上线: fd=", fd, " mtu=", mtu, " dns=", dnsUp)
	return 0
}

func stopVPN() (rc int) {
	defer func() {
		if r := recover(); r != nil {
			_ = r
			rc = -99
		}
	}()
	runMu.Lock()
	defer runMu.Unlock()
	if runStack == nil {
		return 1 // 未运行
	}
	err := runStack.Close()
	_ = runDev.Close()
	runStack, runDev, runStats = nil, nil, nil
	protectTsfn.Store(nil)
	if err != nil {
		return -1
	}
	return 0
}

// ---- 出站防回环（protect 回握）----

// protectBind 出站 socket 建立后、connect 前经 VpnConnection.protect 绕过 TUN。
func protectBind(network, address string, conn syscall.RawConn) error {
	var opErr error
	err := conn.Control(func(fd uintptr) {
		if notifyProtect(int64(fd)) != 0 {
			opErr = fmt.Errorf("protect(%d) 回握超时，放弃拨号（防回环）", fd)
		}
	})
	if err != nil {
		return err
	}
	return opErr
}

// notifyProtect 通知 JS protect(id, fd) 并等待 setProtected(id) 回握。
// 未注册回调（protectTsfn 为 nil）时直接放行（壳未接 protect 的降级路径）。
func notifyProtect(fd int64) int {
	tsfn := protectTsfn.Load()
	if tsfn == nil {
		return 0
	}
	id := protectSeq.Add(1)
	ch := make(chan struct{}, 1)
	protectWait.Store(id, ch)
	defer protectWait.Delete(id)

	tsfn.Call(tsfn.Env.ValueOf(id), tsfn.Env.ValueOf(fd))

	select {
	case <-ch:
		return 0
	case <-time.After(5 * time.Second):
		olog := &ohosLogger{}
		olog.Warn("protect 回握超时: id=", id, " fd=", fd, "（JS 事件循环被限流？）")
		return -1
	}
}

// recoverExport NAPI 导出的崩溃边界：panic 时不把崩溃抛进 JS 引擎。
func recoverExport(env js.Env) {
	if r := recover(); r != nil {
		olog := &ohosLogger{}
		olog.Error("NAPI 导出 panic: ", r)
	}
}

func main() {} // c-shared 必需
