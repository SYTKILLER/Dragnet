//go:build android && cgo

package main

/*
#include <android/log.h>
#include <stdlib.h>

static void dg_log(int prio, const char *msg) {
	__android_log_print(prio, "Dragnet", "%s", msg);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// androidLogger 把内核日志写到 logcat（tag: Dragnet）。
type androidLogger struct{}

func (l *androidLogger) log(prio C.int, args ...any) {
	msg := fmt.Sprint(args...)
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	C.dg_log(prio, cmsg)
}

func (l *androidLogger) Trace(args ...any) {}
func (l *androidLogger) Debug(args ...any) {}
func (l *androidLogger) Info(args ...any)  { l.log(C.ANDROID_LOG_INFO, args...) }
func (l *androidLogger) Warn(args ...any)  { l.log(C.ANDROID_LOG_WARN, args...) }
func (l *androidLogger) Error(args ...any) { l.log(C.ANDROID_LOG_ERROR, args...) }
func (l *androidLogger) Fatal(args ...any) { l.log(C.ANDROID_LOG_FATAL, args...) }
func (l *androidLogger) Panic(args ...any) { l.log(C.ANDROID_LOG_FATAL, args...) }
