package subscribe

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type testLogger struct{}

func (testLogger) Info(args ...any)  {}
func (testLogger) Warn(args ...any)  {}
func (testLogger) Error(args ...any) {}

const sampleRules = `! test list
||ads.one^
||ads.two^
||ads.three^
||ads.four^
||ads.five^
@@||ok.one^
@@||ok.two^
||ads.six^
||ads.seven^
||ads.eight^
||ads.nine^
`

// TestConditionalUpdate 用本地 httptest 验证完整条件更新闭环：
// 200+ETag → 落盘 → 二次请求带 If-None-Match → 304 跳过。
func TestConditionalUpdate(t *testing.T) {
	var hits int32
	etag := `"v1"`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		if inm := r.Header.Get("If-None-Match"); inm == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		w.Header().Set("Last-Modified", "Mon, 26 Oct 2026 00:00:00 GMT")
		_, _ = w.Write([]byte(sampleRules))
	}))
	defer srv.Close()

	dir := t.TempDir()
	cfg := Config{Sources: []Source{{Name: "test", URL: srv.URL + "/rules.txt"}}}
	m := NewManager(dir, cfg, func() error { return nil }, testLogger{})

	res := m.RefreshOnce()
	if res.Updated != 1 || res.Failed != 0 {
		t.Fatalf("首轮 RefreshResult = %+v, want Updated=1", res)
	}
	// 落盘与 meta 校验。
	b, err := os.ReadFile(filepath.Join(dir, "test.txt"))
	if err != nil || !strings.Contains(string(b), "||ads.one^") {
		t.Fatalf("订阅文件未正确落盘: %v", err)
	}
	var meta meta
	if mb, err := os.ReadFile(filepath.Join(dir, "test.txt.meta.json")); err != nil {
		t.Fatalf("meta 缺失: %v", err)
	} else if json.Unmarshal(mb, &meta) != nil || meta.ETag != etag || meta.Lines != 11 {
		t.Fatalf("meta 内容异常: %s", mb)
	}

	res = m.RefreshOnce()
	if res.Skipped != 1 || res.Updated != 0 {
		t.Fatalf("次轮 RefreshResult = %+v, want Skipped=1", res)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Fatalf("请求次数 = %d, want 2", got)
	}
}

// TestValidationBad 拒绝体积超限与行数不足的响应。
func TestValidationBad(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("! only comment\n"))
	}))
	defer srv.Close()

	dir := t.TempDir()
	cfg := Config{Sources: []Source{{Name: "bad", URL: srv.URL}}}
	m := NewManager(dir, cfg, func() error { return nil }, testLogger{})
	res := m.RefreshOnce()
	if res.Failed != 1 {
		t.Fatalf("RefreshResult = %+v, want Failed=1（行数不足应拒绝）", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "bad.txt")); !os.IsNotExist(err) {
		t.Fatalf("被拒响应不得落盘")
	}
}

// TestAtomicReplace 验证已有文件被原子替换且临时文件被清理。
func TestAtomicReplace(t *testing.T) {
	var body atomic.Value
	body.Store(sampleRules)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body.Load().(string)))
	}))
	defer srv.Close()

	dir := t.TempDir()
	cfg := Config{Sources: []Source{{Name: "x", URL: srv.URL}}}
	m := NewManager(dir, cfg, func() error { return nil }, testLogger{})
	if m.RefreshOnce().Updated != 1 {
		t.Fatalf("首轮更新失败")
	}
	body.Store("! v2\n" + strings.Repeat("||new.example^\n", 12))
	if m.RefreshOnce().Updated != 1 {
		t.Fatalf("二次更新失败")
	}
	b, _ := os.ReadFile(filepath.Join(dir, "x.txt"))
	if !strings.Contains(string(b), "||new.example^") {
		t.Fatalf("文件未替换: %s", b)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".sub-") {
			t.Fatalf("临时文件残留: %s", e.Name())
		}
	}
}

// TestLoadConfigFallback 配置缺失时回退默认三源。
func TestLoadConfigFallback(t *testing.T) {
	cfg, err := LoadConfig(filepath.Join(t.TempDir(), "absent.json"))
	if err != nil {
		t.Fatalf("缺省配置应回退默认: %v", err)
	}
	if len(cfg.Sources) != 3 || cfg.Sources[0].Name != "anti-AD" {
		t.Fatalf("默认配置异常: %+v", cfg.Sources)
	}
	if m := NewManager(t.TempDir(), cfg, func() error { return nil }, testLogger{}); m.Interval() != 24*time.Hour {
		t.Fatalf("默认间隔应为 24h")
	}
}
