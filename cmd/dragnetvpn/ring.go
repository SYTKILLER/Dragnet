// 本文件刻意不带构建标签：环形缓冲是纯 Go 逻辑，宿主（Windows）下也要参与
// 编译与单测（go test ./cmd/dragnetvpn -race）。包主体 main.go / log_android.go
// 仅在 android&&cgo 下构建，stub_main.go 补齐宿主侧的 package main 桩。
package main

import (
	"sync"
	"time"
)

// logRingCapacity 是内核事件环形日志容量（方向1：Android 内核事件日志）。
const logRingCapacity = 1024

// logEvent 是壳层事件环形日志的一条记录（字段对齐 internal/ipc.BlockEvent，
// 但 ipc 带 Windows 构建标签不可引用；此处 Dest/Process 直接存字符串形态，
// 并带单调递增 id 供壳层游标增量拉取）。
type logEvent struct {
	ID      uint64
	Ts      int64 // unix 毫秒
	Kind    string
	Action  string
	Domain  string
	Rule    string
	List    string
	Dest    string
	Process string
}

// ring 是固定容量的最近事件环形缓冲（镜像 internal/wincore/ctl.go 的
// blockRing 写法）。互斥由包级 logMu 承担：ID 分配与写入同锁，保证缓冲内
// 位置顺序与 id 顺序严格一致（否则游标拉取会漏事件）。
type ring struct {
	buf []logEvent
	hi  int // 下一个写入位
	n   int // 已填充条数
}

var (
	logMu     sync.Mutex
	logRing   = ring{buf: make([]logEvent, logRingCapacity)}
	logNextID uint64
)

// logAdd 追加一条事件：分配单调递增 id 后写入环形缓冲（满则覆盖最旧）。
// ID/Ts 为空时在此补齐；必须快速返回（转发路径同步调用）。
func logAdd(ev logEvent) {
	logMu.Lock()
	defer logMu.Unlock()
	logNextID++
	ev.ID = logNextID
	if ev.Ts == 0 {
		ev.Ts = time.Now().UnixMilli()
	}
	logRing.buf[logRing.hi] = ev
	logRing.hi = (logRing.hi + 1) % len(logRing.buf)
	if logRing.n < len(logRing.buf) {
		logRing.n++
	}
}

// logsAfter 返回 id>cursor 的最旧 max 条（升序）与当前最大 id。
// events 超过 max 时返回最旧一段，调用方以返回的游标续拉、不丢事件；
// max<=0 时只探测当前水位。
func logsAfter(cursor uint64, max int) ([]logEvent, uint64) {
	logMu.Lock()
	defer logMu.Unlock()
	if max < 0 {
		max = 0
	}
	out := make([]logEvent, 0, min(max, logRing.n))
	for i := 0; i < logRing.n && len(out) < max; i++ {
		// 最旧条目位于 hi-n 位置，向 hi 方向扫描即 id 升序。
		idx := (logRing.hi - logRing.n + i + len(logRing.buf)) % len(logRing.buf)
		if ev := logRing.buf[idx]; ev.ID > cursor {
			out = append(out, ev)
		}
	}
	return out, logNextID
}
