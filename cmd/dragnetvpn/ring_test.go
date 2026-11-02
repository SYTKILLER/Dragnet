package main

import (
	"fmt"
	"sync"
	"testing"
)

// resetLogRing 重建包级环形缓冲（测试间隔离）。
func resetLogRing(capacity int) {
	logMu.Lock()
	defer logMu.Unlock()
	logRing = ring{buf: make([]logEvent, capacity)}
	logNextID = 0
}

func ids(evs []logEvent) []uint64 {
	out := make([]uint64, len(evs))
	for i, ev := range evs {
		out[i] = ev.ID
	}
	return out
}

func equalUint64(a, b []uint64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestLogAddSequence 基本写入：id 单调递增、升序返回、游标为当前最大 id。
func TestLogAddSequence(t *testing.T) {
	resetLogRing(8)
	for i := 0; i < 3; i++ {
		logAdd(logEvent{Kind: "dns", Action: "block", Domain: fmt.Sprintf("d%d.example", i)})
	}
	evs, cur := logsAfter(0, 10)
	if got := ids(evs); !equalUint64(got, []uint64{1, 2, 3}) {
		t.Fatalf("ids = %v, want [1 2 3]", got)
	}
	if cur != 3 {
		t.Fatalf("cursor = %d, want 3", cur)
	}
	if evs[0].Ts == 0 {
		t.Fatal("ts 未自动填充")
	}
	if evs[0].ID == evs[1].ID {
		t.Fatal("id 未去重")
	}
}

// TestLogsAfterCursor 游标语义：只返回 id>cursor 的条目；cursor 到底后为空。
func TestLogsAfterCursor(t *testing.T) {
	resetLogRing(8)
	for i := 0; i < 4; i++ {
		logAdd(logEvent{Kind: "tcp", Action: "relay"})
	}
	evs, _ := logsAfter(2, 10)
	if got := ids(evs); !equalUint64(got, []uint64{3, 4}) {
		t.Fatalf("cursor=2 ids = %v, want [3 4]", got)
	}
	if evs, cur := logsAfter(4, 10); len(evs) != 0 || cur != 4 {
		t.Fatalf("cursor=4 应为空，got %v cur=%d", ids(evs), cur)
	}
	if evs, _ := logsAfter(99, 10); len(evs) != 0 {
		t.Fatalf("cursor 超前应为空，got %v", ids(evs))
	}
}

// TestLogsAfterMaxZero max<=0 只探测水位不取事件。
func TestLogsAfterMaxZero(t *testing.T) {
	resetLogRing(8)
	logAdd(logEvent{Kind: "dns", Action: "forward"})
	evs, cur := logsAfter(0, 0)
	if len(evs) != 0 || cur != 1 {
		t.Fatalf("max=0 应只返回水位，got %v cur=%d", ids(evs), cur)
	}
}

// TestLogRingWraparound 覆盖回绕：容量满后覆盖最旧，仅剩最近 capacity 条。
func TestLogRingWraparound(t *testing.T) {
	resetLogRing(4)
	for i := 0; i < 6; i++ {
		logAdd(logEvent{Kind: "udp", Action: "block"})
	}
	evs, cur := logsAfter(0, 100)
	if got := ids(evs); !equalUint64(got, []uint64{3, 4, 5, 6}) {
		t.Fatalf("回绕后 ids = %v, want [3 4 5 6]", got)
	}
	if cur != 6 {
		t.Fatalf("cursor = %d, want 6", cur)
	}
	// 被覆盖的旧 id 不可再取：cursor=0 已取尽。
	if evs, _ := logsAfter(0, 100); len(evs) != 4 {
		t.Fatalf("重复拉取应同样为 4 条，got %d", len(evs))
	}
}

// TestLogsAfterOldestMax 超过 max 返回最旧一段（升序），续拉不丢事件。
func TestLogsAfterOldestMax(t *testing.T) {
	resetLogRing(1024)
	for i := 0; i < 6; i++ {
		logAdd(logEvent{Kind: "dns", Action: "block"})
	}
	evs, cur := logsAfter(0, 2)
	if got := ids(evs); !equalUint64(got, []uint64{1, 2}) {
		t.Fatalf("最旧 2 条 = %v, want [1 2]", got)
	}
	if cur != 6 {
		t.Fatalf("cursor = %d, want 6（游标应是当前最大 id）", cur)
	}
	evs, _ = logsAfter(uint64(evs[len(evs)-1].ID), 100)
	if got := ids(evs); !equalUint64(got, []uint64{3, 4, 5, 6}) {
		t.Fatalf("续拉 = %v, want [3 4 5 6]", got)
	}
}

// TestLogsAfterSkipsOverwrittenCursor 游标所指条目被覆盖后仍能正确续拉
// （消费方长时间未拉取、环形缓冲已绕满一圈的场景）。
func TestLogsAfterSkipsOverwrittenCursor(t *testing.T) {
	resetLogRing(4)
	for i := 0; i < 6; i++ {
		logAdd(logEvent{Kind: "dns", Action: "block"})
	}
	// 消费方停在 cursor=2（该条目已被覆盖）：应返回现存条目中 id>2 的全部。
	evs, _ := logsAfter(2, 100)
	if got := ids(evs); !equalUint64(got, []uint64{3, 4, 5, 6}) {
		t.Fatalf("cursor=2（已覆盖）ids = %v, want [3 4 5 6]", got)
	}
}

// TestLogAddConcurrent 并发写入（-race）：id 唯一且严格对应写入总量，
// 缓冲内容与 id 顺序一致。
func TestLogAddConcurrent(t *testing.T) {
	resetLogRing(1024)
	const workers, per = 8, 200
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < per; i++ {
				logAdd(logEvent{Kind: "tcp", Action: "relay", Domain: fmt.Sprintf("w%d-%d", w, i)})
			}
		}(w)
	}
	wg.Wait()
	evs, cur := logsAfter(0, logRingCapacity)
	if cur != workers*per {
		t.Fatalf("cursor = %d, want %d", cur, workers*per)
	}
	if len(evs) != logRingCapacity {
		t.Fatalf("环满应存 %d 条，got %d", logRingCapacity, len(evs))
	}
	seen := make(map[uint64]bool, len(evs))
	prev := uint64(0)
	for _, ev := range evs {
		if ev.ID <= prev {
			t.Fatalf("id 非升序：%d 后出现 %d", prev, ev.ID)
		}
		if seen[ev.ID] {
			t.Fatalf("id 重复：%d", ev.ID)
		}
		seen[ev.ID] = true
		prev = ev.ID
	}
	// 缓冲内 id 升序（位置顺序=id 顺序）⇒ 游标续拉不丢：最后一批 id 连续。
	if prev != cur {
		t.Fatalf("最新 id = %d, want %d", prev, cur)
	}
}
