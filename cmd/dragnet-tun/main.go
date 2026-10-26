//go:build windows

// dragnet-tun 是罗网 Dragnet 的 Windows CLI（M1 MVP）。
//
// 链路与共享装配见 internal/wincore（服务壳 cmd/dragnetd 共用同一 Run）。
// 运行需管理员（建 TUN + 改路由 + DNS 接管）。
// 编译：go build -tags with_gvisor ./cmd/dragnet-tun
package main

import (
	"context"
	"flag"
	"log"
	"net/netip"
	"os"
	"os/signal"
	"syscall"

	"github.com/SYTKILLER/Dragnet/internal/wincore"
)

func main() {
	lists := flag.String("lists", "build/rules", "规则目录（.txt），缺目录时仅用内置种子")
	inet4 := flag.String("inet4", "172.19.0.1/30", "TUN IPv4 地址/掩码")
	mtu := flag.Uint("mtu", 1500, "TUN MTU")
	tunName := flag.String("tun-name", "Dragnet", "TUN 适配器名")
	ifaceName := flag.String("iface", "", "出站绑定的物理网卡名；缺省自动取默认路由网卡（TUN 建立前判定）")
	dnsUp := flag.String("dns", "223.5.5.5:53", "上游 DNS")
	dnsTimeout := flag.Duration("dns-timeout", wincore.DefaultDNSTimeout, "上游 DNS 超时")
	subConfig := flag.String("subscribe", "", "订阅配置 JSON（设置后按周期后台条件更新并热切换；缺省关闭）")
	noDNSTakeover := flag.Bool("no-dns-takeover", false, "禁用 DNS 接管（诊断用；毒化应答可旁路）")
	noIPC := flag.Bool("no-ipc", false, "禁用本机控制管道（GUI/CLI 控制面）")
	verbose := flag.Bool("v", false, "打印 sing-tun 内部调试日志")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	upAddr, err := netip.ParseAddrPort(*dnsUp)
	if err != nil {
		log.Fatalf("解析 -dns: %v", err)
	}

	opts := wincore.CoreOptions{
		Lists: *lists, Inet4: *inet4, MTU: uint32(*mtu),
		TunName: *tunName, IfaceName: *ifaceName,
		DNSUp: upAddr, DNSTimeout: *dnsTimeout,
		SubscribeConfig: *subConfig,
		NoDNSTakeover:   *noDNSTakeover, NoIPC: *noIPC,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := wincore.Run(ctx, opts, wincore.NewLogAdapter(*verbose)); err != nil {
		log.Fatalf("内核异常退出: %v", err)
	}
	log.Printf("已清理（TUN 适配器、WFP 规则与系统 DNS 随进程结束还原）")
}
