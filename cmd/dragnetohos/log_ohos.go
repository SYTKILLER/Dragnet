//go:build ohos && cgo

package main

/*
#cgo LDFLAGS: -lhilog_ndk.z

#include <hilog/log.h>
#include <stdlib.h>

static void dg_hilog(int sev, const char *msg) {
    OH_LOG_Print(LOG_APP, sev, 0xD22E0, "Dragnet", "%{public}s", msg);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// ohosLogger 把内核日志写到 hilog（tag: Dragnet，hdc shell hilog 查看口径
// 与 Android logcat 对齐）。
type ohosLogger struct{}

func (l *ohosLogger) log(sev C.int, args ...any) {
	msg := fmt.Sprint(args...)
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	C.dg_hilog(sev, cmsg)
}

func (l *ohosLogger) Trace(args ...any) {}
func (l *ohosLogger) Debug(args ...any) { l.log(C.LOG_DEBUG, args...) }
func (l *ohosLogger) Info(args ...any)  { l.log(C.LOG_INFO, args...) }
func (l *ohosLogger) Warn(args ...any)  { l.log(C.LOG_WARN, args...) }
func (l *ohosLogger) Error(args ...any) { l.log(C.LOG_ERROR, args...) }
func (l *ohosLogger) Fatal(args ...any) { l.log(C.LOG_FATAL, args...) }
func (l *ohosLogger) Panic(args ...any) { l.log(C.LOG_FATAL, args...) }
