# 罗网 Dragnet · 进度看板（多设备接力）

> **接力协议**：任何设备完成/变更任务后，必须更新本文件并推送。这里是跨设备的唯一进度事实源。
> 完整调研与技术文档仅存在于源机器 `C:\Data\Dragnet\docs\`（按仓库原则 gitignored 不入库），本文件自带基线摘要，接力设备可凭此冷启动。
> 项目：广告拦截器。仓库 https://github.com/SYTKILLER/Dragnet.git（分支 main）。GitHub 需走代理时用 127.0.0.1:7890（仅对 github.com 配置了 git 代理）。

## 当前状态（更新于 2026-10-24）

- 阶段：**P0 可行性验证 —— 环境准备完毕，PoC 待开工**
- 决策状态：技术选型已批准（见下方基线摘要），无未决阻塞项

## 技术基线摘要（已批准，不可回退）

- 方案名：**「Go 统一核心＋平台薄适配」**
- 构成：Go 自研统一内核（mihomo 思想干净室）+ urlfilter 规则引擎（GPL）+ sing-tun（GPL，仅 Windows TUN）+ Flutter/Flutter-OH 三端薄壳 GUI；整机 GPL-3.0
- 平台：仅 Windows / Android / HarmonyOS NEXT（鸿蒙是独立可行性关卡，不按 Android 类推）
- v1 定位：**免证书的域名与连接级广告、跟踪器拦截**；不做 MITM（v2），不承诺完整 AdGuard 语法（规则支持矩阵四档：支持/忽略/降级/拒绝加载）
- 关键修正：真实 IP↔域名有界缓存为主路径，fake-ip 仅可选；规则二进制预编译延后（v1=原始文本+启动编译+原子切换）；Matcher 有语义契约（三值 Verdict：放行/阻断/无法判断 + 命中订阅/规则ID/原文/依据 DNS·SNI·IP·进程/降级标记）+ 跨引擎一致性测试集
- 平台细节：Windows 服务+GUI 本机 IPC（ACL/鉴权/版本化）；移动端 C ABI（线程模型/内存所有权/崩溃边界）；日志内核侧聚合批处理；连接日志默认本地+可清理脱敏

## 里程碑与任务看板

| 阶段 | 任务 | 状态 | 备注 |
|---|---|---|---|
| P0 | P0-W Windows TUN+进程识别 PoC | ⬜ 待办 | 本机可开工（需管理员运行） |
| P0 | P0-A Android VpnService 最小链路 PoC | 🔶 环境就绪/缺真机 | SDK+NDK 已装，需用户插真机开 USB 调试 |
| P0 | P0-H 鸿蒙最小链路 PoC | 🔶 环境就绪/缺签名 | DevEco 6.1.1.300 已装（含模拟器）；需华为账号登录+证书签名；另需 go-ohos 补丁工具链（源机器待克隆） |
| P0 | P0-R 规则管线基准（urlfilter 装真实订阅实测启动/内存/吞吐） | ⬜ 待办 | 纯 Go，本机可立即开工，无平台依赖 |
| M0 | M0-1 规则支持矩阵定稿 | ⬜ 待办 | 初稿口径在源机器 docs/tech/03 §2 |
| M0 | M0-2 威胁模型 | ⬜ 待办 | |
| M0 | M0-3 Verdict 语义契约 + 一致性测试集骨架 | ⬜ 待办 | |
| M1 | Windows CLI MVP | ⬜ | 依赖 P0-W |
| M2 | Android 核心薄切片 | ⬜ | 依赖 P0-A |
| M3 | 订阅更新 + Windows GUI | ⬜ | Flutter 桌面（届时装 Flutter） |
| M4 | Android 完整端；鸿蒙按 P0-H 结论分支 | ⬜ | Flutter-OH（届时装） |
| M5 | 兼容性与性能硬化 | ⬜ | |
| v2 | MITM 增强层 | ⬜ | v1 预留钩子：cosmetic 规则位、白名单域名→MITM 分流点 |

可并行组：{P0-W, P0-R, M0-1/2/3} 无设备依赖可同时推进；{P0-A, P0-H} 等用户解锁设备后并行。

## 开发环境（源机器 C:\Data\Dragnet，Windows 11 x64）

| 工具 | 状态 | 位置/版本 |
|---|---|---|
| Go | ✅ | C:\Data\tools\go（1.27.3 zip 免管理员安装；PATH 已入 ~/.bashrc；GOPROXY=goproxy.cn） |
| Android SDK | ✅ | C:\Data\tools\android-sdk（cmdline-tools + platform-tools r37.0.1；NDK 30.0.16248370 安装中→查 ndk 目录确认；JAVA 用 DevEco JBR 21，_JAVA_OPTIONS 走 7890 代理） |
| DevEco Studio | ✅ | 6.1.1.300（自带 OpenHarmony SDK/hdc/模拟器；hdc 在 sdk/default/openharmony/toolchains/） |
| Java（独立 JDK） | ➖ 未装 | sdkmanager 已用 DevEco JBR 替代；Android Gradle 构建时再定 |
| Flutter | ➖ 未装 | M3 再装（含 Flutter-OH 适配），P0 不需要 |
| go-ohos 工具链 | ⬜ 未装 | 鸿蒙 PoC 时按 ClashBox 配方取（GitHub 需代理） |

其他设备首次接力：装 Go（≥1.27）→ clone 本仓库 → 读本文件 → 按任务看板认领。移动端开发另需 Android Studio（或仅 cmdline-tools）与 DevEco Studio（华为官网，非大陆 IP 签名会被屏蔽）。

## 更新日志

- 2026-10-24：技术选型批准并经评审修订（过程见源机器 docs/tech/01-03）；建立本看板；源机器完成环境准备（Go/Android SDK/DevEco 核查）。
