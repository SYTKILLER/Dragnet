//go:build windows

package ipc

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type fakeHandler struct {
	allowed []string
	blocks  []BlockEvent
}

func (f *fakeHandler) Status() any { return Status{Blocks: len(f.blocks)} }
func (f *fakeHandler) Blocks(n int) []BlockEvent {
	if n > len(f.blocks) {
		n = len(f.blocks)
	}
	return f.blocks[:n]
}
func (f *fakeHandler) Allow(d string) error {
	f.allowed = append(f.allowed, d)
	return nil
}
func (f *fakeHandler) Deny(d string) error {
	out := f.allowed[:0]
	for _, x := range f.allowed {
		if x != d {
			out = append(out, x)
		}
	}
	f.allowed = out
	return nil
}
func (f *fakeHandler) Allowlist() []string { return f.allowed }

// TestPipeRoundTrip 真实命名管道往返：status/blocks/allow/allowlist 四条命令。
// 本机无特权可跑（命名管道不触碰网络栈）。
func TestPipeRoundTrip(t *testing.T) {
	h := &fakeHandler{blocks: []BlockEvent{
		{Time: time.Now(), Kind: "dns", Domain: "ads.example.com", Rule: "||ads.example.com^", List: "starter"},
	}}
	srv, err := NewServer(h, true)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	go func() { _ = srv.Serve() }()
	time.Sleep(200 * time.Millisecond) // 等监听就绪

	// status
	resp, err := Call(Request{Cmd: "status"}, 5*time.Second)
	if err != nil || !resp.OK {
		t.Fatalf("status: %v %+v", err, resp)
	}
	var st Status
	json.Unmarshal(resp.Data, &st)
	if st.Blocks != 1 {
		t.Fatalf("status.Blocks = %d, want 1", st.Blocks)
	}

	// blocks
	resp, _ = Call(Request{Cmd: "blocks", Count: 10}, 5*time.Second)
	var evs []BlockEvent
	json.Unmarshal(resp.Data, &evs)
	if len(evs) != 1 || evs[0].Domain != "ads.example.com" {
		t.Fatalf("blocks = %+v", evs)
	}

	// allow + allowlist + deny
	if resp, _ = Call(Request{Cmd: "allow", Domain: "safe.example.com"}, 5*time.Second); !resp.OK {
		t.Fatalf("allow: %+v", resp)
	}
	if resp, _ = Call(Request{Cmd: "allowlist"}, 5*time.Second); !resp.OK || !strings.Contains(string(resp.Data), "safe.example.com") {
		t.Fatalf("allowlist: %+v", resp)
	}
	if resp, _ = Call(Request{Cmd: "deny", Domain: "safe.example.com"}, 5*time.Second); !resp.OK {
		t.Fatalf("deny: %+v", resp)
	}
	if resp, _ = Call(Request{Cmd: "allowlist"}, 5*time.Second); strings.Contains(string(resp.Data), "safe.example.com") {
		t.Fatalf("deny 后仍在白名单: %+v", resp)
	}
}

// TestDispatchGuard 协议层防护：坏版本/未知命令/非法域名。
func TestDispatchGuard(t *testing.T) {
	srv, _ := NewServer(&fakeHandler{}, true)
	cases := []struct {
		line string
		want string
	}{
		{`{"v":99,"cmd":"status"}`, "version mismatch"},
		{`{"v":1,"cmd":"nope"}`, "unknown cmd"},
		{`{"v":1,"cmd":"allow","domain":"bad domain;rm"}`, "invalid domain"},
		{`not-json`, "bad request"},
	}
	for _, c := range cases {
		resp := srv.dispatch([]byte(c.line))
		if resp.OK || !strings.Contains(resp.Err, c.want) {
			t.Fatalf("dispatch(%s) = %+v, want err %q", c.line, resp, c.want)
		}
	}
}
