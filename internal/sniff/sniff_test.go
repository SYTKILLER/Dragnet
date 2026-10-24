package sniff

import (
	"encoding/binary"
	"testing"
)

// buildClientHello 构造一个最小但结构正确的 ClientHello（TLS 记录层），
// serverName 为空时不带 server_name 扩展。
func buildClientHello(t *testing.T, serverName string, extraExts ...[]byte) []byte {
	t.Helper()

	var exts []byte
	if serverName != "" {
		name := []byte(serverName)
		var sni []byte
		sni = binary.BigEndian.AppendUint16(sni, uint16(len(name)+3))
		sni = append(sni, 0) // host_name 类型
		sni = binary.BigEndian.AppendUint16(sni, uint16(len(name)))
		sni = append(sni, name...)
		exts = binary.BigEndian.AppendUint16(exts, 0) // server_name
		exts = binary.BigEndian.AppendUint16(exts, uint16(len(sni)))
		exts = append(exts, sni...)
	}
	for _, e := range extraExts {
		exts = append(exts, e...)
	}

	var ch []byte
	ch = append(ch, 3, 3)                     // client version
	ch = append(ch, make([]byte, 32)...)      // random
	ch = append(ch, 0)                        // session_id 空
	ch = binary.BigEndian.AppendUint16(ch, 2) // cipher_suites 长度
	ch = append(ch, 0x13, 0x01)               // 一个 cipher suite
	ch = append(ch, 1, 0)                     // compression: null
	ch = binary.BigEndian.AppendUint16(ch, uint16(len(exts)))
	ch = append(ch, exts...)

	var hs []byte
	hs = append(hs, 1) // client_hello
	hs = append(hs, byte(len(ch)>>16), byte(len(ch)>>8), byte(len(ch)))
	hs = append(hs, ch...)

	var rec []byte
	rec = append(rec, 22, 3, 1)
	rec = binary.BigEndian.AppendUint16(rec, uint16(len(hs)))
	rec = append(rec, hs...)
	return rec
}

func TestTLSClientHelloSNI(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"带 SNI", buildClientHello(t, "ads.example.com"), "ads.example.com"},
		{"无 SNI", buildClientHello(t, ""), ""},
		{"大写与尾点归一化", buildClientHello(t, "ADS.Example.COM."), "ads.example.com"},
		{"非 TLS 数据", []byte("GET / HTTP/1.1\r\nHost: x.com\r\n\r\n"), ""},
		{"空数据", nil, ""},
		{"截断记录", []byte{22, 3, 1, 0, 50, 1, 0, 0, 40}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := TLSClientHelloSNI(c.data); got != c.want {
				t.Fatalf("TLSClientHelloSNI = %q, want %q", got, c.want)
			}
		})
	}
}

// 一个非 server_name 扩展不应干扰解析。
func TestTLSClientHelloSNIWithOtherExts(t *testing.T) {
	otherExt := []byte{0xff, 0x01, 0, 1, 0} // renegotiation_info 空扩展
	data := buildClientHello(t, "tracker.net", otherExt)
	if got := TLSClientHelloSNI(data); got != "tracker.net" {
		t.Fatalf("SNI = %q, want tracker.net", got)
	}
}

func TestHTTPHost(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{
			"标准 GET",
			[]byte("GET /a?b=1 HTTP/1.1\r\nHost: ads.example.com:8080\r\nUser-Agent: t\r\n\r\n"),
			"ads.example.com",
		},
		{"host 大小写", []byte("GET / HTTP/1.0\r\nhOsT: TRACK.io.\r\n\r\n"), "track.io"},
		{"非 HTTP", []byte{22, 3, 1, 0, 0}, ""},
		{"无 Host", []byte("GET / HTTP/1.1\r\n\r\n"), ""},
		{"响应不是请求", []byte("HTTP/1.1 200 OK\r\nHost: x\r\n\r\n"), ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := HTTPHost(c.data); got != c.want {
				t.Fatalf("HTTPHost = %q, want %q", got, c.want)
			}
		})
	}
}
