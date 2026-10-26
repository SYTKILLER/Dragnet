//go:build windows

// dragnetctl 的 IPC 客户端模式：通过本机控制管道查询运行中的拦截服务
// （状态 / 最近阻断回溯 / 白名单管理）。零特权可连（管道 DACL 放行当前用户）。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/SYTKILLER/Dragnet/internal/ipc"
)

const pipeUsage = `控制运行中的 dragnet-tun（经本机管道）:
  dragnetctl -pipe status                 服务状态
  dragnetctl -pipe blocks [-n 20]         最近阻断回溯
  dragnetctl -pipe allow example.com      白名单放行（热切换）
  dragnetctl -pipe deny example.com       移出白名单
  dragnetctl -pipe allowlist              查看白名单`

func pipeMain(args []string) int {
	// flag 包遇首个位置参数即停止解析，这里手动拆出子命令再解析其余 flag。
	cmd := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("pipe", flag.ExitOnError)
	n := fs.Int("n", 20, "blocks 返回条数")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, pipeUsage)
		return 2
	}
	if cmd == "" {
		fmt.Fprintln(os.Stderr, pipeUsage)
		return 2
	}
	req := ipc.Request{Cmd: cmd, Count: *n}
	if fs.NArg() > 0 {
		req.Domain = fs.Arg(0)
	}

	resp, err := ipc.Call(req, 10*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl pipe:", err)
		return 1
	}
	if !resp.OK {
		fmt.Fprintf(os.Stderr, "dragnetctl pipe: 服务端错误: %s\n", resp.Err)
		return 1
	}
	return printPipe(cmd, resp)
}

func printPipe(cmd string, resp *ipc.Response) int {
	switch cmd {
	case "status":
		var st ipc.Status
		json.Unmarshal(resp.Data, &st)
		fmt.Println("服务运行中, uptime:", st.Uptime)
	case "blocks":
		var evs []ipc.BlockEvent
		json.Unmarshal(resp.Data, &evs)
		if len(evs) == 0 {
			fmt.Println("暂无阻断记录")
			return 0
		}
		for _, e := range evs {
			fmt.Printf("%s [%s] %s rule=%s list=%s dest=%s process=%s\n",
				e.Time.Format("15:04:05"), e.Kind, orDash(e.Domain),
				orDash(e.Rule), orDash(e.List), orDash(e.Dest), orDash(e.Process))
		}
	case "allowlist":
		var list []string
		json.Unmarshal(resp.Data, &list)
		if len(list) == 0 {
			fmt.Println("白名单为空")
			return 0
		}
		fmt.Println(strings.Join(list, "\n"))
	default:
		fmt.Println("完成")
	}
	return 0
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
