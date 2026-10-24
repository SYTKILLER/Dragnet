//go:build !windows

// Package procid 进程反查的平台适配：非 Windows 平台返回空（无进程证据）。
// Android/Linux 的 PID 识别在各自 PoC 任务（P0-A 等）中另行实现。
package procid

import "net/netip"

// Cache 与 Windows 版签名一致，查询恒空。
type Cache struct{}

// NewCache 创建空实现。
func NewCache() *Cache { return &Cache{} }

// LookupTCP 恒返回空串。
func (*Cache) LookupTCP(netip.AddrPort) string { return "" }

// LookupUDP 恒返回空串。
func (*Cache) LookupUDP(netip.AddrPort) string { return "" }
