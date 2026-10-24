package ipcache

import (
	"net/netip"
	"testing"
	"time"
)

var base = time.Unix(1700000000, 0)

func TestPutGet(t *testing.T) {
	c := New(8, time.Minute)
	ip := netip.MustParseAddr("93.184.216.34")
	c.Put(ip, "example.com", base)
	if got := c.Domain(ip, base); got != "example.com" {
		t.Fatalf("Domain = %q, want example.com", got)
	}
	if c.Len() != 1 {
		t.Fatalf("Len = %d, want 1", c.Len())
	}
}

func TestOverwrite(t *testing.T) {
	c := New(8, time.Minute)
	ip := netip.MustParseAddr("1.2.3.4")
	c.Put(ip, "dns-guess.example", base)
	c.Put(ip, "sni.example", base.Add(time.Second))
	if got := c.Domain(ip, base.Add(time.Second)); got != "sni.example" {
		t.Fatalf("Domain = %q, want sni.example（强证据应覆盖弱证据）", got)
	}
	if c.Len() != 1 {
		t.Fatalf("Len = %d, want 1", c.Len())
	}
}

func TestTTLExpiry(t *testing.T) {
	c := New(8, time.Minute)
	ip := netip.MustParseAddr("1.2.3.4")
	c.Put(ip, "example.com", base)
	if got := c.Domain(ip, base.Add(DefaultTTL+time.Second)); got != "" {
		t.Fatalf("Domain = %q, want 空（应过期）", got)
	}
	if c.Len() != 0 {
		t.Fatalf("Len = %d, want 0（过期应清理）", c.Len())
	}
}

func TestLRUEviction(t *testing.T) {
	c := New(3, time.Minute)
	ips := []netip.Addr{
		netip.MustParseAddr("10.0.0.1"),
		netip.MustParseAddr("10.0.0.2"),
		netip.MustParseAddr("10.0.0.3"),
	}
	for i, ip := range ips {
		c.Put(ip, "d"+string(rune('a'+i)), base)
	}
	// 访问最旧条目使其变新。
	if got := c.Domain(ips[0], base); got != "da" {
		t.Fatalf("precondition Domain = %q", got)
	}
	c.Put(netip.MustParseAddr("10.0.0.4"), "dd", base)
	if got := c.Domain(ips[1], base); got != "" {
		t.Fatalf("ips[1] 应被 LRU 淘汰，got %q", got)
	}
	if got := c.Domain(ips[0], base); got != "da" {
		t.Fatalf("ips[0] 应保留，got %q", got)
	}
	if c.Len() != 3 {
		t.Fatalf("Len = %d, want 3（有界）", c.Len())
	}
}

func TestInvalidInput(t *testing.T) {
	c := New(8, time.Minute)
	c.Put(netip.Addr{}, "example.com", base)
	c.Put(netip.MustParseAddr("1.2.3.4"), "", base)
	if c.Len() != 0 {
		t.Fatalf("Len = %d, want 0", c.Len())
	}
	if got := c.Domain(netip.Addr{}, base); got != "" {
		t.Fatalf("无效 IP 应返回空，got %q", got)
	}
}
