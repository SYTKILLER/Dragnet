//go:build windows

// Package procid 通过连接的本地端点反查发起进程（Windows）。
//
// TUN 捕获的包在 NAT 前五元组保持原样，因此包的源端点即进程 socket 的
// 本地端点：对 TCP 查 GetExtendedTcpTable，对 UDP 查 GetExtendedUdpTable，
// 命中本地端点得到 PID，再取进程映像名。表查询无需特权。
//
// TODO(测试机验证): 端口字节序按 MSDS"network byte order"用前两字节大端
// 解析，与 gopsutil 等实现一致；真机核对若干常见进程后固化。
package procid

import (
	"encoding/binary"
	"net/netip"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	afInet            = 2
	tcpTableOwnerPID  = 5 // TCP_TABLE_OWNER_PID_ALL
	udpTableOwnerPID  = 1 // UDP_TABLE_OWNER_PID
	processQueryLimit = 0x1000

	nameTTL = 30 * time.Second // 进程会退出，映像名缓存短 TTL
)

var (
	iphlpapi                = windows.NewLazySystemDLL("iphlpapi.dll")
	procGetExtendedTcpTable = iphlpapi.NewProc("GetExtendedTcpTable")
	procGetExtendedUdpTable = iphlpapi.NewProc("GetExtendedUdpTable")
)

// MIB_TCPROW_OWNER_PID / MIB_UDPTABLE_OWNER_PID 的固定布局（x64 无对齐填充，
// 全部 DWORD）。
const (
	tcpRowSize = 24 // state, localAddr, localPort, remoteAddr, remotePort, pid
	udpRowSize = 12 // localAddr, localPort, pid
)

type nameEntry struct {
	name   string
	expiry time.Time
}

// Cache 缓存 PID→进程名，减少逐流 OpenProcess 开销。
type Cache struct {
	mu sync.Mutex
	m  map[uint32]nameEntry
}

// NewCache 创建进程名缓存。
func NewCache() *Cache {
	return &Cache{m: make(map[uint32]nameEntry)}
}

// LookupTCP 返回本地端点所属进程名（不含路径）；查不到返回空串。
func (c *Cache) LookupTCP(local netip.AddrPort) string {
	return c.lookup(true, local)
}

// LookupUDP 返回本地 UDP 端点所属进程名；查不到返回空串。
func (c *Cache) LookupUDP(local netip.AddrPort) string {
	return c.lookup(false, local)
}

func (c *Cache) lookup(tcp bool, local netip.AddrPort) string {
	if !local.IsValid() {
		return ""
	}
	pid, ok := findOwner(tcp, local)
	if !ok || pid == 0 {
		return ""
	}
	return c.name(pid)
}

func (c *Cache) name(pid uint32) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	if e, ok := c.m[pid]; ok {
		if now.Before(e.expiry) {
			return e.name
		}
		delete(c.m, pid)
	}
	n := processName(pid)
	c.m[pid] = nameEntry{name: n, expiry: now.Add(nameTTL)}
	return n
}

func processName(pid uint32) string {
	h, err := windows.OpenProcess(processQueryLimit, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, syscall.MAX_PATH+1)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &size); err != nil {
		return ""
	}
	return filepath.Base(windows.UTF16ToString(buf[:size]))
}

// findOwner 遍历扩展连接表，匹配本地端点返回 PID。
func findOwner(tcp bool, local netip.AddrPort) (uint32, bool) {
	rowSize := tcpRowSize
	getTable := procGetExtendedTcpTable
	tableClass := tcpTableOwnerPID
	if !tcp {
		rowSize, getTable, tableClass = udpRowSize, procGetExtendedUdpTable, udpTableOwnerPID
	}

	wantAddr := local.Addr().As4()
	// 本地端点在 TUN 捕获的包中保持原样；UDP 端口 0 无意义直接跳过。
	if local.Port() == 0 {
		return 0, false
	}

	var size uint32
	// 首次传 size=0 拿所需缓冲；表在两次调用间可能增长，循环重试。
	for range 3 {
		if size == 0 {
			size = 64 * 1024
		}
		buf := make([]byte, size)
		r1, _, _ := getTable.Call(
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(unsafe.Pointer(&size)),
			0,      // bOrder: 返回已排序（可为 FALSE）
			afInet, // AF_INET
			uintptr(tableClass),
			0,
		)
		if r1 == 0 { // NO_ERROR
			return scanTable(buf, size, rowSize, wantAddr, local.Port())
		}
		if r1 != 122 { // ERROR_INSUFFICIENT_BUFFER
			return 0, false
		}
		if size == 0 {
			return 0, false
		}
	}
	return 0, false
}

// scanTable 解析 MIB_TCPTABLE_OWNER_PID / MIB_UDPTABLE_OWNER_PID：
// dwNumEntries(4) + entries。
func scanTable(buf []byte, size uint32, rowSize int, wantAddr [4]byte, wantPort uint16) (uint32, bool) {
	n := int(binary.LittleEndian.Uint32(buf))
	maxEntries := (int(size) - 4) / rowSize
	if n > maxEntries {
		n = maxEntries
	}
	for i := range n {
		row := buf[4+i*rowSize : 4+(i+1)*rowSize]
		var addr [4]byte
		copy(addr[:], row[4:8]) // localAddr：网络字节序，按内存字节直接取
		if addr != wantAddr {
			continue
		}
		// localPort：网络字节序占低 16 位，即字段前两字节大端。
		if binary.BigEndian.Uint16(row[8:10]) != wantPort {
			continue
		}
		pid := binary.LittleEndian.Uint32(row[rowSize-4:])
		return pid, pid != 0
	}
	return 0, false
}
