//go:build windows

// Package windns 管理 Windows 系统级 DNS 服务器配置（per-adapter）。
//
// 用途（P0-W round5 疑点的根因修复）：TUN 接管全局路由后，Windows DNS 客户端
// 仍可能向物理网卡的 DNS 并发竞速，GFW 毒化应答先于内核应答到达——查询根本
// 不进 TUN，DNS 级拦截被旁路。标准对策是拦截期间把所有带 DNS 的物理适配器
// 指向 TUN 内置 DNS，退出时还原（本包提供快照/接管/还原三原语）。
//
// 实现：GetAdaptersAddresses 快照 + iphlpapi.SetInterfaceDnsSettings（Win10
// 1809+；目标平台 Win11，不再做旧系统 netsh/注册表回退）。只触碰 NameServer
// 标志位，不动适配器的搜索域等其他配置。原为 DHCP 下发的 DNS 还原后成为等值
// 静态列表，属 PoC 已知限制（M3 订阅管线再完善）。
package windns

import (
	"fmt"
	"net/netip"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Snapshot 是一个适配器的原始 DNS 配置。
type Snapshot struct {
	LUID uint64
	GUID windows.GUID
	Name string
	V4   []netip.Addr // 原IPv4 DNS 服务器
	V6   []netip.Addr // 原IPv6 DNS 服务器
}

// SnapshotAdapters 记录所有"当前配置了 DNS 服务器"的非回环适配器（排除
// excludeName，通常是 TUN 适配器本身）。
func SnapshotAdapters(excludeName string) ([]Snapshot, error) {
	const flags = windows.GAA_FLAG_SKIP_UNICAST |
		windows.GAA_FLAG_SKIP_ANYCAST |
		windows.GAA_FLAG_SKIP_MULTICAST |
		windows.GAA_FLAG_INCLUDE_ALL_INTERFACES

	var size uint32
	var buf []byte
	for range 3 {
		buf = make([]byte, max(size, 16*1024))
		size = uint32(len(buf))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0,
			(*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			break
		}
		if err != syscall.ERROR_INSUFFICIENT_BUFFER {
			return nil, fmt.Errorf("windns: GetAdaptersAddresses: %w", err)
		}
		buf = nil
	}
	if buf == nil {
		return nil, fmt.Errorf("windns: GetAdaptersAddresses 缓冲重试耗尽")
	}

	var out []Snapshot
	for aa := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); aa != nil; aa = aa.Next {
		if aa.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK {
			continue
		}
		name := windows.UTF16PtrToString(aa.FriendlyName)
		if strings.EqualFold(name, excludeName) {
			continue
		}
		guid, err := windows.GUIDFromString(windows.BytePtrToString(aa.AdapterName))
		if err != nil {
			continue // GUID 解析失败的适配器跳过（不影响其余）
		}
		snap := Snapshot{LUID: aa.Luid, GUID: guid, Name: name}
		for dns := aa.FirstDnsServerAddress; dns != nil; dns = dns.Next {
			if dns.Address.Sockaddr == nil {
				continue
			}
			family := (*rawSockaddr)(unsafe.Pointer(dns.Address.Sockaddr)).Family
			switch family {
			case windows.AF_INET:
				in := (*rawSockaddrIn4)(unsafe.Pointer(dns.Address.Sockaddr))
				snap.V4 = append(snap.V4, netip.AddrFrom4(in.Addr))
			case windows.AF_INET6:
				in6 := (*rawSockaddrIn6)(unsafe.Pointer(dns.Address.Sockaddr))
				snap.V6 = append(snap.V6, netip.AddrFrom16(in6.Addr))
			}
		}
		if len(snap.V4)+len(snap.V6) > 0 {
			out = append(out, snap)
		}
	}
	return out, nil
}

// SetDNS 把适配器在指定地址族的 DNS 服务器列表整体替换为 servers
// （空列表=清除）。只动 NameServer，不触碰搜索域。需要管理员。
func SetDNS(guid *windows.GUID, family int, servers []netip.Addr) error {
	var filtered []string
	for _, s := range servers {
		if (s.Is4() && family == windows.AF_INET) || (s.Is6() && family == windows.AF_INET6) {
			filtered = append(filtered, s.String())
		}
	}
	servers16, err := windows.UTF16PtrFromString(strings.Join(filtered, ","))
	if err != nil {
		return err
	}
	settings := &dnsInterfaceSettings{
		Version:    dnsInterfaceSettingsVersion1,
		Flags:      dnsFlagNameserver,
		NameServer: servers16,
	}
	if family == windows.AF_INET6 {
		settings.Flags |= dnsFlagIPv6
	}
	r1, _, e1 := procSetInterfaceDnsSettings.Call(
		uintptr(unsafe.Pointer(guid)),
		uintptr(unsafe.Pointer(settings)))
	if r1 != 0 {
		if e1 == syscall.ERROR_PROC_NOT_FOUND {
			return fmt.Errorf("windns: SetInterfaceDnsSettings 不可用（需 Win10 1809+）")
		}
		return fmt.Errorf("windns: SetInterfaceDnsSettings: %w", e1)
	}
	return nil
}

// FlushResolverCache 清空 Windows DNS 客户端缓存（DnsFlushResolverCache）。
func FlushResolverCache() error {
	ret, _, e1 := windows.NewLazySystemDLL("dnsapi.dll").NewProc("DnsFlushResolverCache").Call()
	if ret == 0 {
		return fmt.Errorf("windns: DnsFlushResolverCache: %w", e1)
	}
	return nil
}

// ---- iphlpapi SetInterfaceDnsSettings 绑定 ----

// rawSockaddr* 是 Win32 sockaddr 家族的最小镜像（仅用于解析 DNS 服务器地址）。
type rawSockaddr struct {
	Family uint16
	Data   [126]byte
}

type rawSockaddrIn4 struct {
	Family uint16
	Port   uint16
	Addr   [4]byte
	Zero   [8]byte
}

type rawSockaddrIn6 struct {
	Family   uint16
	Port     uint16
	Flowinfo uint32
	Addr     [16]byte
	ScopeId  uint32
}

var (
	procSetInterfaceDnsSettings = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("SetInterfaceDnsSettings")
)

const (
	dnsInterfaceSettingsVersion1 = 1
	dnsFlagIPv6                  = 0x0001
	dnsFlagNameserver            = 0x0002
)

// dnsInterfaceSettings 与 Windows SDK 的 DNS_INTERFACE_SETTINGS (Version 1)
// 布局一致（amd64；未覆盖 32 位构建）。
type dnsInterfaceSettings struct {
	Version             uint32
	_                   [4]byte
	Flags               uint64
	Domain              *uint16
	NameServer          *uint16
	SearchList          *uint16
	RegistrationEnabled uint32
	RegisterAdapterName uint32
	EnableLLMNR         uint32
	QueryAdapterName    uint32
	ProfileNameServer   *uint16
}
