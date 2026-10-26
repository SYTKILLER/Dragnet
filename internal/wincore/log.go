//go:build windows

package wincore

import (
	"fmt"
	"log"
)

// logAdapter 实现 sing 的 logger.Logger（内核与 sing-tun 共用），落 std log。
type LogAdapter struct{ verbose bool }

// NewLogAdapter 构建日志适配器；verbose 打开 TRACE/DEBUG。
func NewLogAdapter(verbose bool) *LogAdapter { return &LogAdapter{verbose: verbose} }

func (l *LogAdapter) Trace(args ...any) {
	if l.verbose {
		log.Println(append([]any{"[TRACE]"}, args...)...)
	}
}
func (l *LogAdapter) Debug(args ...any) {
	if l.verbose {
		log.Println(append([]any{"[DEBUG]"}, args...)...)
	}
}
func (l *LogAdapter) Info(args ...any)  { log.Println(args...) }
func (l *LogAdapter) Warn(args ...any)  { log.Println("[WARN]", fmt.Sprint(args...)) }
func (l *LogAdapter) Error(args ...any) { log.Println("[ERROR]", fmt.Sprint(args...)) }
func (l *LogAdapter) Fatal(args ...any) { log.Fatalf("%s", fmt.Sprint(args...)) }
func (l *LogAdapter) Panic(args ...any) { log.Panicf("%s", fmt.Sprint(args...)) }
