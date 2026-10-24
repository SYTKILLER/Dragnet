// Package ipcache 实现真实 IP↔域名有界缓存（基线 docs/tech/03 §3：真实 IP 缓存
// 为主路径，fake-ip 仅可选）。域名证据来源有两级优先级，由调用方按序覆盖写入：
//
//  1. DNS 响应反查（弱证据，共享 CDN 可能张冠李戴）；
//  2. SNI / HTTP Host 嗅探（强证据，连接级直接观测）。
//
// 缓存有界：容量上限 + 条目 TTL，LRU 淘汰。判定方拿不到证据时按 NoMatch
// 放行（fail-open），绝不按共享 IP 猜测封禁。
package ipcache

import (
	"container/list"
	"net/netip"
	"sync"
	"time"
)

const (
	// DefaultCapacity 默认容量：约容纳一天家庭流量的活跃 DNS 域名。
	DefaultCapacity = 65536
	// DefaultTTL 默认条目存活时间。
	DefaultTTL = 10 * time.Minute
)

type entry struct {
	domain string
	expiry time.Time
	elem   *list.Element // 在 lru 中对应本 IP 的元素，用于 O(1) 上移
}

// Cache 是并发安全的 IP→域名有界 LRU 缓存。
type Cache struct {
	mu  sync.Mutex
	m   map[netip.Addr]entry
	lru *list.List // 元素值为 netip.Addr，前端 = 最近使用
	cap int
	ttl time.Duration
}

// New 创建缓存；capacity/ttl 非正时取默认值。
func New(capacity int, ttl time.Duration) *Cache {
	if capacity <= 0 {
		capacity = DefaultCapacity
	}
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	return &Cache{
		m:   make(map[netip.Addr]entry, capacity/4),
		lru: list.New(),
		cap: capacity,
		ttl: ttl,
	}
}

// Put 记录 IP→域名。新写入总是覆盖旧值并视为最近使用。
func (c *Cache) Put(ip netip.Addr, domain string, now time.Time) {
	if !ip.IsValid() || domain == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.m[ip]; ok {
		c.lru.Remove(e.elem)
	}
	c.m[ip] = entry{
		domain: domain,
		expiry: now.Add(c.ttl),
		elem:   c.lru.PushFront(ip),
	}
	for len(c.m) > c.cap {
		oldest := c.lru.Back()
		if oldest == nil {
			break
		}
		c.lru.Remove(oldest)
		delete(c.m, oldest.Value.(netip.Addr))
	}
}

// Domain 返回 IP 对应的域名证据；不存在或已过期返回空串。
func (c *Cache) Domain(ip netip.Addr, now time.Time) string {
	if !ip.IsValid() {
		return ""
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[ip]
	if !ok {
		return ""
	}
	if now.After(e.expiry) {
		c.lru.Remove(e.elem)
		delete(c.m, ip)
		return ""
	}
	c.lru.MoveToFront(e.elem)
	return e.domain
}

// Len 返回当前条目数。
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m)
}
