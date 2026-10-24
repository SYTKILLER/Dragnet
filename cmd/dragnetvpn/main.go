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
*/
import "C"

import (
	"context"
	"fmt"
	"net/netip"
	"sync"
	"syscall"
	"time"
	"unsafe"

	tun "github.com/sagernet/sing-tun"

	"github.com/SYTKILLER/Dragnet/internal/blocklist"
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

func startVPN(fd int, dnsUp string, mtu int) int {
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

	// 规则：外部加载优先，否则内置种子。
	holderMu.Lock()
	if holder.Current() == nil {
		if err := holder.LoadRules([]engine.NamedRules{{Name: blocklist.StarterName, Text: blocklist.Starter()}}); err != nil {
			holderMu.Unlock()
			return -13
		}
	}
	holderLocal := &holder
	holderMu.Unlock()

	alog := &androidLogger{}
	h := tunstack.New(tunstack.Config{
		Holder:     holderLocal,
		Cache:      ipcache.New(ipcache.DefaultCapacity, ipcache.DefaultTTL),
		DNSUp:      up,
		DNSTimeout: dnsTimeout,
		Bind:       protectBind,
		Log:        alog,
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
		return -15
	}
	if err := dev.Start(); err != nil {
		return -16
	}
	if err := stack.Start(); err != nil {
		return -17
	}
	runDev, runStack = dev, stack
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
	runStack, runDev = nil, nil
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

func recoverPanic(out *C.int, fail C.int) {
	if r := recover(); r != nil {
		_ = r
		*out = fail
	}
}

func main() {} // c-shared 必需
