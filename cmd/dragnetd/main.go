//go:build windows

// dragnetd 把罗网内核装配为 Windows 服务（M3「服务化+崩溃恢复」）。
//
// 与 dragnet-tun 共用 runCore（同一套 TUN/DNS 接管/IPC/订阅逻辑），差别仅是
// 生命周期由 SCM 驱动、日志走系统事件日志之外仍写 stdout（SCM 下重定向由
// 安装时配置）。
//
// 用法：
//
//	dragnetd -run                          # 由 SCM 调起（-install 注册的命令）
//	dragnetd -install [-lists D] ...       # 注册服务（转发其余内核参数，绝对路径化）
//	dragnetd -uninstall                    # 注销服务
//	dragnetd -status                       // 查询服务状态
//
// 恢复策略：注册时配置 FIRST/SECOND/SUBSEQUENT 失败 → 5s 后自动重启，
// 24h 后重置计数（崩溃恢复的 SCM 侧保证；应用层 panic 边界见 tunstack）。
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/SYTKILLER/Dragnet/internal/wincore"
)

const serviceName = "Dragnet"

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	isService, err := svc.IsWindowsService()
	must(err, "判断服务上下文")
	if isService {
		must(svc.Run(serviceName, &dragnetService{}), "运行服务")
		return
	}
	manage(os.Args[1:])
}

type dragnetService struct{}

// Execute 实现 svc.Handler。内核参数从服务注册的 BinaryPathName 附带参数
// 解析（-install 时固化），这里只做生命周期桥接。
func (m *dragnetService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}

	opts, la := serviceOptions(args)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- wincore.Run(ctx, opts, la) }()

	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				cancel()
				err := <-done
				if err != nil {
					log.Printf("内核退出异常: %v", err)
					return false, 1
				}
				return false, 0
			}
		case err := <-done:
			// 内核自行退出（如初始化失败）：非零退出码触发 SCM 恢复策略。
			changes <- svc.Status{State: svc.Stopped}
			if err != nil {
				log.Printf("内核自行退出: %v", err)
				return false, 1
			}
			return false, 0
		}
	}
}

func must(err error, what string) {
	if err != nil {
		log.Fatalf("%s: %v", what, err)
	}
}

// ---- 服务管理子命令 ----

func manage(argv []string) {
	if len(argv) == 0 {
		fmt.Fprintf(os.Stderr, "用法: dragnetd [-run|-install [内核参数...]|-uninstall|-status]\n")
		os.Exit(2)
	}
	switch argv[0] {
	case "-run":
		// 由服务二进制路径直接跑（调试用），行为与 SCM 调起一致。
		must(svc.Run(serviceName, &dragnetService{}), "运行服务")
	case "-install":
		install(argv[1:])
	case "-uninstall":
		uninstall()
	case "-status":
		status()
	default:
		// 其余参数按内核参数透传给前台运行（开发期便利：dragnetd -v -lists ...）
		fmt.Fprintf(os.Stderr, "未知子命令 %q；前台调试请用 dragnet-tun\n", argv[0])
		os.Exit(2)
	}
}

func install(kernelArgs []string) {
	exe, err := os.Executable()
	must(err, "取自身路径")
	// 服务的工作目录是 System32：目录类参数一律绝对路径化。
	args := []string{"-lists", absDefault("build/rules", "C:\\ProgramData\\Dragnet\\rules")}
	for i := 0; i < len(kernelArgs); i++ {
		switch kernelArgs[i] {
		case "-lists", "-subscribe":
			if i+1 < len(kernelArgs) {
				args = append(args, kernelArgs[i], absPath(kernelArgs[i+1]))
				i++
			}
		default:
			args = append(args, kernelArgs[i])
		}
	}

	m, err := mgr.Connect()
	must(err, "连接服务管理器")
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err == nil {
		s.Close()
		fmt.Println("服务已存在，先执行 -uninstall")
		os.Exit(1)
	}
	s, err = m.CreateService(serviceName, exe, mgr.Config{
		DisplayName: "罗网 Dragnet 内核",
		Description: "域名级广告/跟踪拦截内核（TUN + DNS 接管 + 规则热切换）",
		StartType:   mgr.StartAutomatic,
	}, args...)
	must(err, "注册服务")

	// 崩溃恢复：1/2 次失败 5s 重启，其后也重启；24h 无故障重置计数。
	recovery := []mgr.RecoveryAction{{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second}}
	must(s.SetRecoveryActions(recovery, 24*3600), "配置恢复策略")

	defer s.Close()
	fmt.Printf("服务已注册: %s\n  启动: sc start %s\n  参数: %v\n", serviceName, serviceName, args)
}

func uninstall() {
	m, err := mgr.Connect()
	must(err, "连接服务管理器")
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	must(err, "打开服务（未安装?）")
	defer s.Close()
	must(s.Delete(), "删除服务")
	fmt.Println("服务已注销")
}

func status() {
	m, err := mgr.Connect()
	must(err, "连接服务管理器")
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		fmt.Println("未安装")
		return
	}
	defer s.Close()
	st, err := s.Query()
	must(err, "查询状态")
	fmt.Printf("状态: %v\n", st.State)
}

func absPath(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	wd, err := os.Getwd()
	if err != nil {
		return p
	}
	return filepath.Join(wd, p)
}

func absDefault(p, fallback string) string {
	if _, err := os.Stat(p); err == nil {
		return absPath(p)
	}
	return fallback
}
