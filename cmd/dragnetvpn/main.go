//go:build android && cgo

// dragnetvpn 把罗网完整内核（TUN 处理链 + 规则引擎）暴露为 Android 动态库。
// 平台薄壳（Kotlin VpnService）只做三件事：establish 拿 fd、注册 protect、
// 起停内核——拦截语义全部在本库（与 Windows CLI 共用 internal/tunstack）。
//
// 构建脚本：scripts/build-android.sh；产物 build/android/<abi>/libdragnet.so
// 由 Gradle jniLibs 直接引用。
//
// ABI 契约（基线 docs/tech/03 §6：线程模型 / 内存所有权 / 崩溃边界）：
//   - 线程模型：导出函数可被任意 JNI 线程并发调用；内核状态由 atomic 快照
//     与互斥锁保护；protect 调用按需 AttachCurrentThread。
//   - 内存所有权：入参字符串为借用；出参字符串由调用方 DragnetFreeString 释放。
//   - 崩溃边界：每个导出函数 recover 全部 panic，转为负数错误码。
//
// Kotlin 侧对应 com.dragnet.app.DragnetNative（符号名按 JNI 约定固定）。
//
// JNI 导出（9 个）：nativeSetService / nativeStartVpn / nativeStopVpn /
// nativeLoadRules / nativeStats / nativeRuleInfo / nativeMatch /
// nativeLogs（事件环形日志增量拉取）/ nativeLastError（最近一次启动失败原因）。
// 另有 C ABI 3 个：DragnetLoadRules / DragnetMatchDetail / DragnetFreeString。
package main

/*
#include <jni.h>
#include <stdlib.h>

static JavaVM *dg_jvm = NULL;
static jobject dg_service = NULL;
static jmethodID dg_protect_mid = NULL;

// dg_cache_service 缓存 JavaVM、VpnService 全局引用与 protect 方法 ID。
static jint dg_cache_service(JNIEnv *env, jobject service) {
	if ((*env)->GetJavaVM(env, &dg_jvm) != JNI_OK) return -1;
	jobject global = (*env)->NewGlobalRef(env, service);
	if (global == NULL) return -2;
	jclass cls = (*env)->FindClass(env, "android/net/VpnService");
	if (cls == NULL) return -3;
	dg_protect_mid = (*env)->GetMethodID(env, cls, "protect", "(I)Z");
	if (dg_protect_mid == NULL) return -4;
	dg_service = global;
	return 0;
}

// dg_protect_fd 出站防回环：socket 建立后、connect 前调用 VpnService.protect。
static int dg_protect_fd(int fd) {
	JNIEnv *env = NULL;
	int attached = 0;
	if ((*dg_jvm)->GetEnv(dg_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
		if ((*dg_jvm)->AttachCurrentThread(dg_jvm, &env, NULL) != JNI_OK) return -1;
		attached = 1;
	}
	int ok = (*env)->CallBooleanMethod(env, dg_service, dg_protect_mid, fd);
	if (attached) (*dg_jvm)->DetachCurrentThread(dg_jvm);
	return ok == JNI_TRUE ? 0 : -1;
}

static char *dg_jstr(JNIEnv *env, jstring s) {
	return s == NULL ? NULL : (char *)(*env)->GetStringUTFChars(env, s, NULL);
}
static void dg_release_jstr(JNIEnv *env, jstring s, const char *c) {
	if (s != NULL && c != NULL) (*env)->ReleaseStringUTFChars(env, s, c);
}
static jstring dg_new_jstr(JNIEnv *env, const char *c) {
	return c == NULL ? NULL : (*env)->NewStringUTF(env, c);
}
*/
import "C"

import (
	"context"
	"fmt"
	"net/netip"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	tun "github.com/sagernet/sing-tun"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/ipcache"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/tunstack"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// 与 Kotlin DragnetVpnService.kt 中 Builder 配置保持一致。
const (
	tunAddr    = "10.111.222.1/32" // Builder.addAddress
	tunDNSAddr = "10.111.222.3"    // Builder.addDnsServer（进入 TUN 后被劫持）
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

	// 最近一次 startVpn 失败的底层错误文本（nativeLastError 导出；对齐
	// cmd/dragnetohos 的 lastError/setStartErr 样板。空串=从未失败，导出 null；
	// 成功启动时清空）。
	lastErrMu    sync.Mutex
	lastStartErr string
)

// ---- JNI 入口（对应 Kotlin DragnetNative）----

// nativeSetService 注册 VpnService 实例（protect 防回环依赖）。
//
//export Java_com_dragnet_app_DragnetNative_nativeSetService
func Java_com_dragnet_app_DragnetNative_nativeSetService(env *C.JNIEnv, thiz C.jobject, service C.jobject) (rc C.jint) {
	defer recoverJNI(&rc)
	return C.jint(C.dg_cache_service(env, service))
}

// nativeStartVpn 启动内核：fd 来自 VpnService.Builder.establish()。
// 返回 0 成功，负数为错误码。
//
//export Java_com_dragnet_app_DragnetNative_nativeStartVpn
func Java_com_dragnet_app_DragnetNative_nativeStartVpn(env *C.JNIEnv, thiz C.jobject, fd C.jint, dnsUp C.jstring, mtu C.jint) (rc C.jint) {
	defer recoverJNI(&rc)
	cs := C.dg_jstr(env, dnsUp)
	defer C.dg_release_jstr(env, dnsUp, cs)
	return C.jint(startVPN(int(fd), C.GoString(cs), int(mtu)))
}

// nativeStopVpn 停止内核并释放 TUN。
//
//export Java_com_dragnet_app_DragnetNative_nativeStopVpn
func Java_com_dragnet_app_DragnetNative_nativeStopVpn(env *C.JNIEnv, thiz C.jobject) (rc C.jint) {
	defer recoverJNI(&rc)
	return C.jint(stopVPN())
}

// nativeLoadRules 从目录加载外部订阅规则（filesDir/rules/*.txt），0 成功。
// 须在 nativeStartVpn 之前调用；加载失败时保留原引擎（内置种子）。
//
//export Java_com_dragnet_app_DragnetNative_nativeLoadRules
func Java_com_dragnet_app_DragnetNative_nativeLoadRules(env *C.JNIEnv, thiz C.jobject, dir C.jstring) (rc C.jint) {
	defer recoverJNI(&rc)
	cs := C.dg_jstr(env, dir)
	defer C.dg_release_jstr(env, dir, cs)
	if cs == nil {
		return -1
	}
	srcs, err := rules.SourcesFromDir(C.GoString(cs))
	if err != nil {
		return -2
	}
	if err := holder.Load(srcs); err != nil {
		return -3
	}
	return 0
}

// nativeStats 返回运行统计 JSON（未运行返回 null）。
//
//export Java_com_dragnet_app_DragnetNative_nativeStats
func Java_com_dragnet_app_DragnetNative_nativeStats(env *C.JNIEnv, thiz C.jobject) (rs C.jstring) {
	defer recoverStats(&rs)
	runMu.Lock()
	h := runStats
	start := runStart
	runMu.Unlock()
	if h == nil {
		var jnil C.jstring
		return jnil
	}
	s := h.Snapshot()
	// JSON 数字字段手动拼装，避免引入 encoding/json 体积
	json := fmt.Sprintf(
		`{"uptime_sec":%d,"dns_blocked":%d,"dns_forwarded":%d,"tcp_blocked":%d,"tcp_relayed":%d,"udp_blocked":%d,"udp_relayed":%d,"cache":%d}`,
		int(time.Since(start).Seconds()),
		s.DNSBlocked, s.DNSForwarded, s.TCPBlocked, s.TCPRelayed, s.UDPBlocked, s.UDPRelayed, s.CacheLen)
	cs := C.CString(json)
	defer C.free(unsafe.Pointer(cs))
	return C.dg_new_jstr(env, cs)
}

// nativeRuleInfo 返回当前已加载规则的规模信息 JSON {lists,rule_lines,rule_bytes}
// （对齐 cmd/dragnetohos 的 ruleInfo；未加载返回 null）。无网络副作用。
//
//export Java_com_dragnet_app_DragnetNative_nativeRuleInfo
func Java_com_dragnet_app_DragnetNative_nativeRuleInfo(env *C.JNIEnv, thiz C.jobject) (rs C.jstring) {
	defer recoverStats(&rs)
	holderMu.Lock()
	e := holder.Current()
	holderMu.Unlock()
	if e == nil {
		var jnil C.jstring
		return jnil
	}
	s := e.Stats()
	cs := C.CString(fmt.Sprintf(`{"lists":%d,"rule_lines":%d,"rule_bytes":%d}`,
		s.Lists, s.RuleLines, s.RuleTextBytes))
	defer C.free(unsafe.Pointer(cs))
	return C.dg_new_jstr(env, cs)
}

// nativeMatch 按域名查询当前引擎（无网络副作用，供壳内自检/排障，对齐
// cmd/dragnetohos 的 match）。返回 JSON {"action","rule","list"}；引擎空载或
// 域名为空返回 null。
//
//export Java_com_dragnet_app_DragnetNative_nativeMatch
func Java_com_dragnet_app_DragnetNative_nativeMatch(env *C.JNIEnv, thiz C.jobject, domain C.jstring) (rs C.jstring) {
	defer recoverStats(&rs)
	cs := C.dg_jstr(env, domain)
	defer C.dg_release_jstr(env, domain, cs)
	if cs == nil {
		var jnil C.jstring
		return jnil
	}
	holderMu.Lock()
	h := holder
	holderMu.Unlock()
	if h.Current() == nil {
		var jnil C.jstring
		return jnil
	}
	res := matchHolder(&h, C.GoString(cs))
	cs2 := C.CString(fmt.Sprintf(`{"action":"%s","rule":"%s","list":"%s"}`,
		res.Action, jsonEscape(res.RuleText), jsonEscape(res.List)))
	defer C.free(unsafe.Pointer(cs2))
	return C.dg_new_jstr(env, cs2)
}

// nativeLogs 增量拉取内核事件环形日志（方向1）：返回 id>cursor 的最旧 500 条
// （升序）与当前最大 id。JSON 手工拼装（与 nativeStats 同风格，字符串经
// jsonEscape）：
//
//	{"cursor":<当前最大id>,"events":[{"id":N,"ts":N,"kind":"dns","action":"block",
//	  "domain":"","rule":"","list":"","dest":"","process":""}]}
//
// 空输出为 "events":[]；壳层以返回的 cursor 续拉、不丢事件。
//
//export Java_com_dragnet_app_DragnetNative_nativeLogs
func Java_com_dragnet_app_DragnetNative_nativeLogs(env *C.JNIEnv, thiz C.jobject, cursor C.jlong) (rs C.jstring) {
	defer recoverStats(&rs)
	cur := uint64(cursor)
	if cursor < 0 {
		cur = 0
	}
	events, maxID := logsAfter(cur, 500)
	var b strings.Builder
	b.WriteString(`{"cursor":`)
	b.WriteString(fmt.Sprint(maxID))
	b.WriteString(`,"events":[`)
	for i, ev := range events {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b,
			`{"id":%d,"ts":%d,"kind":"%s","action":"%s","domain":"%s","rule":"%s","list":"%s","dest":"%s","process":"%s"}`,
			ev.ID, ev.Ts,
			jsonEscape(ev.Kind), jsonEscape(ev.Action), jsonEscape(ev.Domain),
			jsonEscape(ev.Rule), jsonEscape(ev.List), jsonEscape(ev.Dest),
			jsonEscape(ev.Process))
	}
	b.WriteString(`]}`)
	cs := C.CString(b.String())
	defer C.free(unsafe.Pointer(cs))
	return C.dg_new_jstr(env, cs)
}

// nativeLastError 返回最近一次 startVpn 失败的底层错误文本（"rc=-17 <错误>"）；
// 从未失败/已成功启动返回 null。错误码语义不变，只是把原因带出崩溃边界。
//
//export Java_com_dragnet_app_DragnetNative_nativeLastError
func Java_com_dragnet_app_DragnetNative_nativeLastError(env *C.JNIEnv, thiz C.jobject) (rs C.jstring) {
	defer recoverStats(&rs)
	lastErrMu.Lock()
	s := lastStartErr
	lastErrMu.Unlock()
	if s == "" {
		var jnil C.jstring
		return jnil
	}
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return C.dg_new_jstr(env, cs)
}

// jsonEscape 极简 JSON 字符串转义（规则原文含引号/反斜杠/控制符时保真）。
func jsonEscape(s string) string {
	buf := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			buf = append(buf, '\\', c)
		case c == '\n':
			buf = append(buf, '\\', 'n')
		case c == '\r':
			buf = append(buf, '\\', 'r')
		case c == '\t':
			buf = append(buf, '\\', 't')
		case c < 0x20:
			buf = append(buf, fmt.Sprintf(`\u%04x`, c)...)
		default:
			buf = append(buf, c)
		}
	}
	return string(buf)
}

// ---- 规则匹配 C ABI（与 JNI 共存，供测试与未来 NAPI 复用）----

// DragnetLoadRules 从目录加载全部 .txt 规则并原子切换当前引擎；0 成功。
//
//export DragnetLoadRules
func DragnetLoadRules(dir *C.char) (rc C.int) {
	defer recoverPanic(&rc, -1)
	if dir == nil {
		return -1
	}
	srcs, err := rules.SourcesFromDir(C.GoString(dir))
	if err != nil {
		return -2
	}
	if err := holder.Load(srcs); err != nil {
		return -3
	}
	return 0
}

// DragnetMatchDetail 匹配域名：返回 verdict.Action；ruleTextOut 非 NULL 时
// 写入命中规则原文指针（调用方用 DragnetFreeString 释放）。
//
//export DragnetMatchDetail
func DragnetMatchDetail(domain *C.char, ruleTextOut **C.char) (rc C.int) {
	defer recoverPanic(&rc, -1)
	if ruleTextOut != nil {
		*ruleTextOut = nil
	}
	if domain == nil {
		return -1
	}
	res := matchHolder(&holder, C.GoString(domain))
	if ruleTextOut != nil && res.RuleText != "" {
		*ruleTextOut = C.CString(res.RuleText)
	}
	return C.int(res.Action)
}

// DragnetFreeString 释放本库返回的字符串。
//
//export DragnetFreeString
func DragnetFreeString(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// ---- 内核起停 ----

// setStartErr 记录最近一次 startVpn 失败原因（nativeLastError 导出）。
func setStartErr(rc int, why string) {
	lastErrMu.Lock()
	lastStartErr = fmt.Sprintf("rc=%d %s", rc, why)
	lastErrMu.Unlock()
}

// clearStartErr 成功启动后清空失败记录（此后 nativeLastError 返回 null）。
func clearStartErr() {
	lastErrMu.Lock()
	lastStartErr = ""
	lastErrMu.Unlock()
}

func startVPN(fd int, dnsUp string, mtu int) (rc int) {
	// 与 cmd/dragnetohos 的 startVPN 同型：在内核侧接住 panic 记录 -99 原因
	// （JNI 层 recoverJNI 仍兜底，但原因文本只有这里拿得到）。
	defer func() {
		if r := recover(); r != nil {
			rc = -99
			setStartErr(-99, fmt.Sprint(r))
		}
	}()
	runMu.Lock()
	defer runMu.Unlock()
	if runStack != nil {
		setStartErr(-10, "内核已在运行")
		return -10 // 已在运行
	}
	up, err := netip.ParseAddrPort(dnsUp)
	if err != nil {
		setStartErr(-11, err.Error())
		return -11
	}
	if fd <= 0 {
		setStartErr(-12, fmt.Sprintf("fd=%d", fd))
		return -12
	}
	if mtu <= 0 {
		mtu = 1500
	}

	// 规则：仅来自外部加载（nativeLoadRules，M4-R1 规则可见性合规——
	// 无任何内嵌种子）。未加载时空载运行（fail-open），显式告警。
	alog := &androidLogger{}
	holderMu.Lock()
	if holder.Current() == nil {
		alog.Warn("无外部规则（filesDir/rules 为空）——空载运行：无任何规则生效（fail-open）")
	}
	holderLocal := &holder
	holderMu.Unlock()

	h := tunstack.New(tunstack.Config{
		Holder:     holderLocal,
		Cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		DNSUp:      up,
		DNSTimeout: dnsTimeout,
		Bind:       protectBind,
		Log:        alog,
		// 事件环形日志（方向1）：OnEvent 已含全部 block 事件，不再接
		// OnBlocked 以免重复。process 在 Android 恒空串（无进程识别）。
		OnEvent: func(ev tunstack.Event) {
			logAdd(logEvent{
				Ts:      ev.Time.UnixMilli(),
				Kind:    ev.Kind,
				Action:  ev.Action,
				Domain:  ev.Domain,
				Rule:    ev.Rule,
				List:    ev.List,
				Dest:    ev.Dest.String(),
				Process: ev.Process,
			})
		},
	})

	prefix := netip.MustParsePrefix(tunAddr)
	options := tun.Options{
		// 路由与地址由 VpnService.Builder 配置，内核只消费 fd。
		FileDescriptor: fd,
		MTU:            uint32(mtu),
		Inet4Address:   []netip.Prefix{prefix},
		Logger:         alog,
	}
	dev, err := tun.New(options)
	if err != nil {
		setStartErr(-14, err.Error())
		return -14
	}
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    context.Background(),
		Tun:        dev,
		TunOptions: options,
		Handler:    h,
		Logger:     alog,
		UDPTimeout: 5 * time.Minute,
	})
	if err != nil {
		setStartErr(-15, err.Error())
		return -15
	}
	if err := dev.Start(); err != nil {
		setStartErr(-16, err.Error())
		return -16
	}
	if err := stack.Start(); err != nil {
		setStartErr(-17, err.Error())
		return -17
	}
	runDev, runStack, runStats = dev, stack, h
	runStart = time.Now()
	clearStartErr()
	alog.Info("罗网内核上线: fd=", fd, " mtu=", mtu, " dns=", dnsUp)
	return 0
}

func stopVPN() int {
	runMu.Lock()
	defer runMu.Unlock()
	if runStack == nil {
		return 1 // 未运行
	}
	err := runStack.Close()
	_ = runDev.Close()
	runStack, runDev, runStats = nil, nil, nil
	if err != nil {
		return -1
	}
	return 0
}

// protectBind 出站防回环：Android 下 protect() 必须在 connect 前对 socket 调用。
func protectBind(network, address string, conn syscall.RawConn) error {
	var opErr error
	err := conn.Control(func(fd uintptr) {
		if C.dg_protect_fd(C.int(fd)) != 0 {
			opErr = fmt.Errorf("VpnService.protect(%d) 失败", fd)
		}
	})
	if err != nil {
		return err
	}
	return opErr
}

func matchHolder(h *rules.Holder, domain string) verdict.Result {
	return h.Match(&engine.Request{Domain: domain, DomainBasis: verdict.BasisDNS})
}

// ---- 崩溃边界 ----

func recoverJNI(out *C.jint) {
	if r := recover(); r != nil {
		_ = r
		*out = -99
	}
}

// recoverStats 是返回 jstring 的导出函数的崩溃边界（返回 null 而非错误码）。
func recoverStats(out *C.jstring) {
	if r := recover(); r != nil {
		_ = r
		var jnil C.jstring
		*out = jnil
	}
}

func recoverPanic(out *C.int, fail C.int) {
	if r := recover(); r != nil {
		_ = r
		*out = fail
	}
}

func main() {} // c-shared 必需
