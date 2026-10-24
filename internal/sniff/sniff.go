// Package sniff 从 TLS ClientHello 与明文 HTTP 请求头中嗅探目标域名。
//
// 免证书方案的域名证据第二来源（第一来源是 DNS 反查，见 internal/ipcache）：
// SNI/Host 是连接级直接观测，证据强于 DNS 反查。解析器只读首个数据分段，
// TLS 握手跨分段分片的情况返回空（调用方按无证据放行，TODO(v1): 缓冲重组）。
package sniff

import (
	"encoding/binary"
	"strings"
)

// TLSClientHelloSNI 从 TLS 记录层报文中提取 ClientHello 的 server_name。
// 非 TLS 握手或解析失败返回空串。容忍记录层之后的填充/多记录不处理——
// 只处理首记录恰好是完整 ClientHello 的常见情形。
func TLSClientHelloSNI(b []byte) string {
	// TLS 记录层: type(1)=22 handshake, version(2), length(2)
	if len(b) < 5 || b[0] != 22 {
		return ""
	}
	recLen := int(binary.BigEndian.Uint16(b[3:5]))
	if recLen < 4 || 5+recLen > len(b) {
		// 记录分片：首记录不含完整握手体。
		return ""
	}
	body := b[5 : 5+recLen]

	// Handshake: type(1)=1 client_hello, length(3)
	if body[0] != 1 {
		return ""
	}
	hsLen := int(body[1])<<16 | int(body[2])<<8 | int(body[3])
	if hsLen < 36 || 4+hsLen > len(body) {
		return ""
	}
	ch := body[4 : 4+hsLen]

	// ClientHello: version(2) random(32) session_id(1+N) cipher_suites(2+N)
	// compression(1+N) extensions(2+N)
	p := 2 + 32
	if len(ch) < p+1 {
		return ""
	}
	p += 1 + int(ch[p]) // session_id
	if len(ch) < p+2 {
		return ""
	}
	p += 2 + int(binary.BigEndian.Uint16(ch[p:p+2])) // cipher_suites
	if len(ch) < p+1 {
		return ""
	}
	p += 1 + int(ch[p]) // compression methods
	if len(ch) < p+2 {
		return ""
	}
	extTotal := int(binary.BigEndian.Uint16(ch[p : p+2]))
	p += 2
	if len(ch) < p+extTotal {
		return ""
	}
	exts := ch[p : p+extTotal]

	// 扩展序列: type(2) length(2) data(N)
	for len(exts) >= 4 {
		extType := binary.BigEndian.Uint16(exts[0:2])
		extLen := int(binary.BigEndian.Uint16(exts[2:4]))
		if 4+extLen > len(exts) {
			return ""
		}
		data := exts[4 : 4+extLen]
		exts = exts[4+extLen:]
		if extType != 0 { // server_name
			continue
		}
		return parseServerName(data)
	}
	return ""
}

// parseServerName 解析 server_name 扩展数据:
// server_name_list(2+N) { name_type(1)=0, length(2), hostname(N) }。
func parseServerName(data []byte) string {
	if len(data) < 2 {
		return ""
	}
	listLen := int(binary.BigEndian.Uint16(data[0:2]))
	if 2+listLen > len(data) {
		return ""
	}
	list := data[2 : 2+listLen]
	if len(list) < 3 || list[0] != 0 {
		return ""
	}
	nameLen := int(binary.BigEndian.Uint16(list[1:3]))
	if 3+nameLen > len(list) {
		return ""
	}
	name := string(list[3 : 3+nameLen])
	if i := strings.IndexByte(name, 0); i >= 0 {
		name = name[:i]
	}
	name = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(name)), ".")
	if name == "" || strings.ContainsAny(name, "\x00\r\n ") {
		return ""
	}
	return name
}

// HTTPHost 从明文 HTTP 请求首包中提取 Host 头。非 HTTP 或缺失返回空串。
func HTTPHost(b []byte) string {
	head := b
	// 只看头部，截断到 \r\n\r\n（若已出现）。
	if i := strings.Index(string(b[:minInt(len(b), 8192)]), "\r\n\r\n"); i >= 0 {
		head = b[:i]
	}
	lines := strings.Split(string(head), "\r\n")
	if len(lines) < 2 {
		return ""
	}
	line0 := lines[0]
	if len(line0) < 8 || !strings.HasSuffix(line0, "HTTP/1.0") && !strings.HasSuffix(line0, "HTTP/1.1") {
		return ""
	}
	for _, ln := range lines[1:] {
		k, v, ok := strings.Cut(ln, ":")
		if !ok || !strings.EqualFold(strings.TrimSpace(k), "host") {
			continue
		}
		host := strings.TrimSpace(v)
		// Host: example.com:8443 —— 去端口。
		if i := strings.LastIndexByte(host, ':'); i >= 0 && !strings.Contains(host[i:], "]") {
			host = host[:i]
		}
		host = strings.TrimSuffix(strings.ToLower(host), ".")
		if host == "" || strings.ContainsAny(host, "\x00\r\n ") {
			return ""
		}
		return host
	}
	return ""
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
