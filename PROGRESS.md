# 罗网 Dragnet · 进度看板（多设备接力）

> **接力协议**：任何设备完成/变更任务后，必须更新本文件并推送。这里是跨设备的唯一进度事实源。
> 完整调研与技术文档仅存在于源机器 `C:\Data\Dragnet\docs\`（按仓库原则 gitignored 不入库），本文件自带基线摘要，接力设备可凭此冷启动。
> 项目：广告拦截器。仓库 https://github.com/SYTKILLER/Dragnet.git（分支 main）。GitHub 需走代理时用 127.0.0.1:7890（仅对 github.com 配置了 git 代理）。

## 设备工作流（2026-10-24 起）

**双机分工**：开发机（源机器，Windows 11）负责编码与编译验证；测试机（高性能设备，后接入）负责运行验证、调试、性能优化与问题修复。

| | 开发机（本机） | 测试机 |
|---|---|---|
| 职责 | 编码、架构、文档、跨平台交叉编译 | 运行验证、TUN/真机/模拟器测试、性能剖析、bug 修复 |
| 验收标准 | **`go build ./...` 通过 + `go vet` 干净 + 无特权单测通过 + 无明显逻辑漏洞（存疑处代码内 TODO 标记）** | 按下方"移交测试清单"逐项跑通并回写结果 |
| 禁止/减少 | 深入运行调试、提权调试循环、真机联调（只在零成本时做一次性冒烟） | — |

**移交测试清单模板**（每个移交件在任务行附命令；测试机执行后把结果写回看板）：
1. `go build ./...` && `go vet ./...`（确认干净）
2. `go test ./...`
3. 各 PoC/demo 的运行命令与预期输出（见任务行）
4. 问题反馈：在看板任务行追加"🔴 问题："记录，修复后由任一机器清除

## 当前状态（更新于 2026-10-24）

- 阶段：**开发机侧待办全部完成，项目进入"测试进度阻塞"状态**：P0-W / P0-A（含 APK）/ M1 长稳 全部移交待测；测试机结果回写后解锁 M2 与后续
- 决策状态：技术选型已批准（见下方基线摘要），无未决阻塞项；威胁模型开放问题见 docs/tech/04 §4

## 技术基线摘要（已批准，不可回退）

- 方案名：**「Go 统一核心＋平台薄适配」**
- 构成：Go 自研统一内核（mihomo 思想干净室）+ urlfilter 规则引擎（GPL）+ sing-tun（GPL，仅 Windows TUN）+ Flutter/Flutter-OH 三端薄壳 GUI；整机 GPL-3.0
- 平台：仅 Windows / Android / HarmonyOS NEXT（鸿蒙是独立可行性关卡，不按 Android 类推）
- v1 定位：**免证书的域名与连接级广告、跟踪器拦截**；不做 MITM（v2），不承诺完整 AdGuard 语法（规则支持矩阵四档：支持/忽略/降级/拒绝加载）
- 关键修正：真实 IP↔域名有界缓存为主路径，fake-ip 仅可选；规则二进制预编译延后（v1=原始文本+启动编译+原子切换）；Matcher 有语义契约（三值 Verdict：放行/阻断/无法判断 + 命中订阅/规则ID/原文/依据 DNS·SNI·IP·进程/降级标记）+ 跨引擎一致性测试集
- 平台细节：Windows 服务+GUI 本机 IPC（ACL/鉴权/版本化）；移动端 C ABI（线程模型/内存所有权/崩溃边界）；日志内核侧聚合批处理；连接日志默认本地+可清理脱敏

## 里程碑与任务看板

> 状态图例：⬜待办 🔧开发机进行中(编码/编译) 📦移交待测(编译过+清单就绪) ✅完成 🔴有问题(附说明) 🔶缺外部条件

| 阶段 | 任务 | 状态 | 备注/移交测试命令 |
|---|---|---|---|
| P0/M1 | D-1 核心契约包 verdict + engine 接口 | 📦 待测 | `go build ./...`；语义见 internal/verdict 包注释 |
| P0 | D-2 urlfilter 适配器 + 规则加载器（原子切换骨架） | 📦 待测 | 已知 TODO：旧引擎关闭的 RCU 竞态窗口（代码内标注）；HostRule 命中信息暂缺 |
| P0-R | D-3 rulebench 基准工具 | 📦 待测 | `bash scripts/fetch-rules.sh && go run ./cmd/rulebench -lists build/rules`；本机初值：3 表 27.7 万行，构建 950ms，堆 47.5MB，65k QPS |
| M1 | D-4 dragnetctl demo CLI | 📦 待测 | `go run ./cmd/dragnetctl -lists build/rules -selftest`（13/13）；stdin 逐行域名→三值判定+命中回溯 |
| P0-W | P0-W Windows TUN+进程识别 PoC | 📦 待测 | 编译过（需 `-tags with_gvisor`）；运行需管理员→测试机。清单见下方"移交测试清单" |
| P0-A | P0-A Android VpnService 最小链路 | 📦 待测 | **壳工程+内核齐**：`bash scripts/build-android.sh` → `cd android && gradle assembleDebug`（Gradle 8.13+JBR21 实测通过，APK 22.4MB 双 ABI）→ adb install；验证清单见 android/README.md；真机→测试机 |
| P0-H | P0-H 鸿蒙最小链路 | 🔶 缺签名 | DevEco 就绪；需华为账号+证书；go-ohos 工具链待取 |
| M0 | M0-1 规则支持矩阵 | 🔧 初稿已落地 | 处置口径固化在 internal/engine/urlfilter.go 注释 + semantic.go 夹具；定稿待真实订阅逐类核对统计 |
| M0 | M0-2 威胁模型 | 🔧 初稿已落地 | 源机器 docs/tech/04-threat-model.md（不入库）：5 资产/4 边界/威胁表+4 个开放问题；开放问题 1（DoH 旁路对策）待讨论 |
| M0 | M0-3 Verdict 契约 + 一致性测试集 | 🔧 测试集扩充完成 | `go test ./...` 语义契约 13/13（三 realm/双 hosts/路径与改写忽略/归一化/反向 important 例外）；夹具可复用于换引擎验收；定稿待真实订阅逐类核对 |
| M1 | Windows CLI MVP（docs/tech/03 §8） | 🔧 代码侧就绪 | dragnet-tun 已覆盖出口标准六要素（DNS 劫持/真实IP映射/SNI 嗅探/urlfilter/REJECT/命中日志）+ 内置种子规则 + panic 边界 + 分钟级运行统计；**长稳运行→测试机** |

demo 范围（开发机已全部交付）：D-1~D-4 + P0-W + P0-A（壳工程与 APK 构建）+ M1 代码侧；测试机接手做全部运行验证（P0-W 清单见上，P0-A 清单见 android/README.md）。

### P0-W 移交测试清单（测试机执行，需管理员）

```bash
go build ./... && go vet ./... && go test ./...        # 1) 干净基线
go build -tags with_gvisor -o build/dragnet-tun.exe ./cmd/dragnet-tun
# 管理员终端运行（先 bash scripts/fetch-rules.sh 拉规则）：
./build/dragnet-tun.exe -lists build/rules             # 2) 默认劫持系统 DNS+全局路由
# 3) 预期：日志出现"出站绑定: <物理网卡>"；浏览器打开含广告站点：
#    - 命中广告域名 → "阻断 DNS ..."（NXDOMAIN）或 "阻断 TCP ..."（SNI）
#    - 普通站点正常出网；nslookup 广告域名返回 NXDOMAIN
# 4) Ctrl+C 退出后：系统 DNS/路由恢复，普通网站可达
# 5) 回写：阻断/漏封样本各记几条（域名+命中规则），核对阻断日志行包含 process=（进程识别证据）
```

已知风险（代码内 TODO 标注）：TCP 握手跨分段时 SNI 可能嗅探不到（放行）；PID 表端口字节序按网络序解析待真机核对；UDP DNS 劫持依赖 sing-tun HijackDNS 路径（两条路径均接，实测为准）。

## 开发环境（源机器 C:\Data\Dragnet，Windows 11 x64）

| 工具 | 状态 | 位置/版本 |
|---|---|---|
| Go | ✅ | C:\Data\tools\go（1.27.3；PATH 在 ~/.bashrc；GOPROXY=goproxy.cn，GOSUMDB=sum.golang.google.cn） |
| Gradle | ✅ | C:\Data\tools\gradle-8.13（直连下载成功；Java 用 DevEco JBR：JAVA_HOME 指向 jbr） |
| Android SDK | ✅ | C:\Data\tools\android-sdk（cmdline-tools + platform-tools r37.0.1 + NDK 30.0.16248370 + platforms;android-36；sdkmanager 的 Java 用 DevEco JBR：`JAVA_HOME='C:\Program Files\Huawei\DevEco Studio\jbr'` + `_JAVA_OPTIONS` 走 7890） |
| DevEco Studio | ✅ | 6.1.1.300（自带 OHOS SDK/hdc/模拟器；hdc 在 sdk/default/openharmony/toolchains/） |
| Flutter | ➖ 未装 | M3 再装；P0/M1 不需要 |
| go-ohos 工具链 | ⬜ 未装 | 鸿蒙 PoC 时按 ClashBox 配方取 |

其他设备首次接力：装 Go（≥1.27）→ clone 本仓库 → `bash scripts/fetch-rules.sh`（拉规则集，可配代理）→ 读本文件按看板认领。移动端另需 Android 工具链与 DevEco Studio（华为官网；非大陆 IP 签名会被屏蔽）。

## 更新日志

- 2026-10-24（六）：P0-A 完成（开发机侧）：架构重构抽出 internal/tunstack 平台无关处理链（Windows CLI 与 Android 内核共用，两端语义一致）；cmd/dragnetvpn Android 内核（JNI：VpnService fd + protect 防回环 + 全套规则 C ABI 导出，dragnetlib 并入）；android/ 薄壳工程（VpnService+程序化 UI，零第三方依赖）；本机 Gradle 8.13+JBR21 assembleDebug 实测通过，APK 22.4MB 双 ABI。全量回归：build（默认+with_gvisor）+vet+test 4 包 + 自检 13/13。**开发机待办清空，阻塞于测试进度**。
- 2026-10-24（五）：M1 代码侧收口：dragnet-tun 内置种子规则（internal/blocklist，go:embed 开箱即用，无订阅目录也可运行）+ 长稳加固（DNS/TCP/UDP 全部回调加 panic 边界，分钟级运行统计：dns/tcp/udp 阻断与中继计数、缓存规模）；M0-3 语义测试集 9→13 条（反向 important 例外、v6 hosts、$dnsrewrite 忽略、大写+尾点归一化），自检输出改动态计数。`go build`（默认+with_gvisor）+`go vet`+`go test` 全过，自检 13/13。规则加载器抽出 LoadRules 内存入口（C ABI 与内置规则共用）。
- 2026-10-24（四）：P0-W 完成（dragnet-tun：sing-tun gVisor 栈 + JudgeFlow 流级阻断 + DNS 劫持 NXDOMAIN + SNI/HTTP Host 嗅探 + ipcache 有界 IP↔域名缓存 + iphlpapi 进程反查，出站绑定物理网卡防回环）；P0-A 编译件完成（dragnetlib C ABI：线程/所有权/崩溃契约，scripts/build-android.sh 产出 arm64-v8a+x86_64 .so，导出已用 llvm-nm 核对）；M0-2 威胁模型初稿（docs/tech/04，源机器）。`go build`（默认+with_gvisor tag）+`go vet`+`go test` 全过；无管理员冒烟：规则加载与出站网卡判定正常，卡 TUN 创建（符合预期）。语义自检 9/9。
- 2026-10-24（三）：D-1~D-4 完成（verdict 契约包 / engine 接口 / urlfilter 适配器 / 原子切换加载器 / rulebench / dragnetctl / fetch-rules 脚本 / 语义测试集）。`go build`+`go vet`+`go test` 全过；本机零特权冒烟：3 表 27.7 万行构建 950ms、堆 47.5MB、65k QPS、语义自检 9/9。待测试机复核基准与长期运行。
- 2026-10-24（二）：确立双机工作流（开发机=编译通过即验收，测试机=运行调试）；demo 范围定为 D-1~D-4+P0-W 编译件；开工 D-1/D-2/D-3/D-4。
- 2026-10-24（一）：技术选型批准并经评审修订（过程见源机器 docs/tech/01-03）；建立本看板；源机器完成环境准备（Go/Android SDK/DevEco）。
