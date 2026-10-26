//go:build !windows

// Package windns 的非 Windows 空实现：Android/Linux 平台的 DNS 接管由各自
// 机制负责（Android 由 VpnService.addDnsServer 天然独占查询路径，无需本包）。
package windns

import "errors"

var errWindowsOnly = errors.New("windns: 仅 Windows 实现")

// Snapshot 在非 Windows 平台恒为空。
type Snapshot struct{}

// SnapshotAdapters 恒返回错误。
func SnapshotAdapters(string) ([]Snapshot, error) { return nil, errWindowsOnly }

// SetDNS 恒返回错误。
func SetDNS(guid any, family int, servers []any) error { return errWindowsOnly }

// FlushResolverCache 恒返回错误。
func FlushResolverCache() error { return errWindowsOnly }
