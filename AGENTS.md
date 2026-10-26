# AGENTS.md · 罗网 Dragnet 运维硬规范（M4-R6）

> 写给在本仓库工作的 AI 智能体与测试机。条款式红线，违反即回滚。
> 借鉴 android-ad-cleaner 的 AGENTS.md 写法（操作红线 + 验收口径）。

## 一、网络红线（2026-10-25 用户指令，绝对禁令）

1. **绝对禁止在宿主机运行任何会建 TUN/改全局路由/改系统 DNS 的程序**——包括本项目自己的 dragnet-tun/dragnetd。即使提权、即使"只跑几秒"。
2. 此类验证一律放虚拟设备：Android 用 AVD（user-mode NAT）；Windows/Linux 用 VM（宿主机不承担 VM 时，等测试机授权窗口）。
3. 普通应用级下载（curl/gradle/sdkmanager 拉包、订阅抓取）不算接管，可正常进行。
4. 若怀疑宿主机曾运行过接管类程序，执行恢复五项核验并回写看板：无 dragnet-tun 进程 / 无 Dragnet 适配器 / 路由表无 172.19 / 系统 DNS 回物理网卡 / 外网连通。
5. 任何 DNS 拦截验证前必须 `ipconfig /flushdns`（Windows DNS 缓存会绕过 TUN）。

## 二、操作纪律

1. **改动前备份**：修改规则文件/配置前先复制原文件（或确认 git 状态干净）。
2. **每条破坏性命令带说明**：rm/reset/force-push 前写明对象与理由。
3. **验证后回写**：每轮测试完成后立即更新 PROGRESS.md 并 push（接力协议：看板是唯一事实源）。
4. **问题分级回写**：看板任务行追加"🔴 问题：…"，修复后清除；环境因素单独立项不混入代码缺陷。
5. **docs/ 与 build/ 不入库**（.gitignore 已覆盖）；研究/测试日志放对应目录，仓库只进最小必需内容。

## 三、验收口径（借鉴"结尾复查，失败不假报成功"）

1. **验证样本跑通才算完成**：规则/订阅/引擎相关改动，交付前必须
   `go run ./cmd/dragnetctl -verify -lists build/rules` 通过（5/5），失败不得标记完成。
2. 代码侧交付的固定三件套：`go build ./...` + `go vet ./...` + `go test ./...` 全绿；
   Windows 内核另加 `-tags with_gvisor` 构建。
3. 语义行为改动必须同步 `internal/engine/semantic.go` 契约用例（当前 13 条），
   并在 docs/tech/05 规则支持矩阵补档位。
4. 规则文件改动遵守"宁可漏封不误封"：新增样本必须是长期稳定域名；
   保护清单（rules/protected-allow.txt）只加不减，除非用户明确要求。

## 四、规则可见性（M4-R1，硬约束）

1. **任何规则不得内嵌进二进制**（go:embed/字符串字面量规则集均禁止）。
   种子=rules/starter.txt，保护清单=rules/protected-allow.txt，
   验证样本=rules/verify-samples.list，全部随分发包外部可见。
2. 规则目录缺失/为空时，内核显式 WARN + 空载运行（fail-open），禁止静默回退到内嵌数据。
3. 测试夹具（semantic.go 的 example.com、rulebench 探测域名）属测试数据，豁免第 1 条。
