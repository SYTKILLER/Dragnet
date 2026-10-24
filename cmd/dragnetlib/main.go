//go:build android && cgo

// dragnetlib 把罗网规则内核暴露为 C ABI 动态库（P0-A：Android VpnService
// 链路的匹配内核；HarmonyOS go-ohos 侧后续复用同一 ABI 形状）。
//
// 构建脚本：scripts/build-android.sh（NDK 交叉编译，产物 build/android/libdragnet.so）。
//
// ABI 契约（基线 docs/tech/03 §5：线程模型 / 内存所有权 / 崩溃边界）：
//   - 线程模型：所有导出函数可被任意线程（含 JNI 线程）并发调用；内核状态
//     由 atomic 快照保护（internal/rules.Holder），热路径无锁。
//   - 内存所有权：入参字符串为借用（调用期间只读，不保存指针）；出参字符串
//     由 Go 侧 C 堆分配，调用方必须用 DragnetFreeString 释放。
//   - 崩溃边界：每个导出函数 recover 全部 panic，转为返回值错误码，绝不向
//     宿主进程外抛；规则加载在旁路完成后原子切换，失败保留旧引擎。
//
// 返回码约定：DragnetLoadRules / DragnetReload 0=成功，负数=失败；
// DragnetMatchDetail 返回 verdict.Action（0=NOMATCH 1=BLOCK 2=ALLOW），
// 负数=内部错误。
package main

// #include <stdlib.h>
import "C"

import (
	"unsafe"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

var holder rules.Holder

// DragnetLoadRules 从目录加载全部 .txt 规则并原子切换当前引擎。
// 返回 0 成功；失败时旧引擎（若有）保持不变。
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

// DragnetReload 等价于 DragnetLoadRules：重读目录原子换引擎。
// TODO(v1): 与 Android 订阅更新管线对齐后改为内存 buffer 传入。

// DragnetMatchDetail 匹配域名：返回 verdict.Action；ruleTextOut 非 NULL 时
// 写入命中规则原文指针（调用方用 DragnetFreeString 释放；无命中写 NULL）。
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
	res := holder.Match(&engine.Request{Domain: C.GoString(domain), DomainBasis: verdict.BasisDNS})
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

// recoverPanic 是崩溃边界：任何 panic 都不逃出导出函数。
func recoverPanic(out *C.int, fail C.int) {
	if r := recover(); r != nil {
		_ = r
		*out = fail
	}
}

func main() {} // c-shared 必需
