//go:build windows

// serviceOptions 把 SCM 注册时固化的内核参数解析为 wincore.CoreOptions。
// 与 dragnet-tun 的 flag 集保持一致（新增参数两处同步）。
package main

import (
	"flag"
	"net/netip"
	"os"
	"path/filepath"

	"github.com/SYTKILLER/Dragnet/internal/wincore"
)

func serviceOptions(args []string) (opts wincore.CoreOptions, la *wincore.LogAdapter) {
	fs := flag.NewFlagSet("dragnetd", flag.ContinueOnError)
	lists := fs.String("lists", "C:\\ProgramData\\Dragnet\\rules", "规则目录")
	inet4 := fs.String("inet4", "172.19.0.1/30", "TUN IPv4 地址/掩码")
	mtu := fs.Uint("mtu", 1500, "TUN MTU")
	tunName := fs.String("tun-name", "Dragnet", "TUN 适配器名")
	ifaceName := fs.String("iface", "", "出站绑定网卡名")
	dnsUp := fs.String("dns", "223.5.5.5:53", "上游 DNS")
	dnsTimeout := fs.Duration("dns-timeout", wincore.DefaultDNSTimeout, "上游 DNS 超时")
	subConfig := fs.String("subscribe", "", "订阅配置 JSON")
	noDNSTakeover := fs.Bool("no-dns-takeover", false, "禁用 DNS 接管")
	noIPC := fs.Bool("no-ipc", false, "禁用控制管道")
	logFile := fs.String("logfile", "C:\\ProgramData\\Dragnet\\logs\\dragnetd.log", "服务日志文件（轮转 16MB）")
	verbose := fs.Bool("v", false, "调试日志")
	_ = fs.Parse(args) // 参数来自注册表，解析失败不致命：走默认值

	la = wincore.NewLogAdapter(*verbose)
	opts = wincore.CoreOptions{
		Lists: *lists, Inet4: *inet4, MTU: uint32(*mtu),
		TunName: *tunName, IfaceName: *ifaceName,
		DNSUp:           netip.MustParseAddrPort(*dnsUp),
		DNSTimeout:      *dnsTimeout,
		SubscribeConfig: *subConfig,
		NoDNSTakeover:   *noDNSTakeover, NoIPC: *noIPC,
		LogFile: *logFile,
	}
	if _, err := os.Stat(opts.Lists); err != nil {
		_ = os.MkdirAll(opts.Lists, 0o755)
	}
	_ = os.MkdirAll(filepath.Dir(*logFile), 0o755)
	return opts, la
}
