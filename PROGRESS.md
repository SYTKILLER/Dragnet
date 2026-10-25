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

**测试机授权规程（2026-10-25 用户指示，长期有效）**：任何需要接管本机网络的测试（启动 dragnet-tun、建 TUN、改全局路由/系统 DNS 的操作），执行前必须获得用户明确同意并约定时间窗口；结束或中断后立即核验恢复并报告——核验项：无 dragnet-tun 进程、无 Dragnet 适配器、路由表无 172.19 条目、系统 DNS 回物理网卡、外网连通。未经同意不得执行。

## 当前状态（更新于 2026-10-25，测试机）

- 阶段：**测试机首轮验证+修复完成，P0-A 构建侧验证通过**：D-1~D-4 全部通过；P0-W 清单 1/2/4/5 项通过，修复 3 个内核缺陷+新增启动清缓存；P0-A 在测试机完成 .so 交叉编译+APK 构建（含修复版内核），真机验证 🔶 待接入手机。**第 3 项 NXDOMAIN 终验与 M1 30 分钟长稳：已暂停，待用户授权网络接管窗口**（见下方"测试机授权规程"）
- 决策状态：技术选型已批准（见下方基线摘要），无未决阻塞项；威胁模型开放问题见 docs/tech/04 §4（round4 实测确认 DoT:853 同样可旁路 DNS 级拦截，与开放问题 1 的 DoH 同类）
- ⚠️ 未决疑点（round5 中断前发现）：系统缓存已清（内核启动自动 flush 生效）后，nslookup 查询 GFW 毒化广告域（pagead2/doubleclick/google-analytics）仍瞬时得到 0.0.0.0/:: 且内核判定日志无记录；非毒化域名（测试规则 bilibili）正常 NXDOMAIN。怀疑 Win11 dnsapi 对多 DNS 服务器（TUN 的 172.19.0.2 与物理网卡的 192.168.1.1）并发竞速、路由器毒化应答先到——若成立，属真实旁路面（应用解析可绕过 TUN），需下轮取证（-v 判定日志+抓包）后定修复方案（候选：AutoRoute 期间改写物理网卡 DNS 或依赖 StrictRoute 核查）

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
| P0/M1 | D-1 核心契约包 verdict + engine 接口 | ✅ 测试机验证通过 | `go build ./...`；语义见 internal/verdict 包注释 |
| P0 | D-2 urlfilter 适配器 + 规则加载器（原子切换骨架） | ✅ 测试机验证通过 | 已知 TODO：旧引擎关闭的 RCU 竞态窗口（代码内标注）；HostRule 命中信息暂缺 |
| P0-R | D-3 rulebench 基准工具 | ✅ 测试机复核通过 | 测试机 3 表 277,089 行：构建 221-234ms、堆 47.9MB、33-36 万 QPS（约 5 倍于开发机，符合高性能设备预期）。🔴 问题（环境）：anti-ad.net 直连被 Cloudflare 限速（30s 仅 18KB），fetch-rules.sh 拉不动；测试机以 docs/rules/anti-AD/adguard.txt 官方副本替代（与在线源同物，行数吻合）。建议脚本注明可用本地副本 |
| M1 | D-4 dragnetctl demo CLI | ✅ 测试机验证通过 | selftest 13/13；stdin 冒烟：4 广告域 BLOCK（含 list/rule/basis 回溯）、2 正常域 NOMATCH |
| P0-W | P0-W Windows TUN+进程识别 PoC | 🔶 终验待授权 | 清单 1/2/4/5 项通过（证据见下方"测试机验证记录"）；修复 3 缺陷+1 卫生项（见 🔴 记录）；第 3 项 NXDOMAIN 终验 round5 中断（用户叫停网络接管），遗留疑点见"当前状态"⚠️ |
| P0-A | P0-A Android VpnService 最小链路 | ✅ 构建侧双机通过 / 🔶 真机待接入 | 测试机复现全链路：NDK r30 交叉编译 .so（导出 6 符号核对一致）→ Gradle 8.13+JDK17 assembleDebug 1m02s → APK 22.4MB 双 ABI（.so 字节级=修复版内核）；真机验证需 Android 手机（adb 37.0.1 就绪） |
| P0-H | P0-H 鸿蒙最小链路 | 🔶 缺签名 | DevEco 就绪；需华为账号+证书；go-ohos 工具链待取 |
| M0 | M0-1 规则支持矩阵 | 🔧 初稿已落地 | 处置口径固化在 internal/engine/urlfilter.go 注释 + semantic.go 夹具；定稿待真实订阅逐类核对统计 |
| M0 | M0-2 威胁模型 | 🔧 初稿已落地 | 源机器 docs/tech/04-threat-model.md（不入库）：5 资产/4 边界/威胁表+4 个开放问题；开放问题 1（DoH 旁路对策）待讨论；测试机 round4 实测：DoT:853 同样旁路 DNS 级拦截（SNI 可嗅到部分如 dot.pub，查询内容不可见） |
| M0 | M0-3 Verdict 契约 + 一致性测试集 | 🔧 测试集扩充完成 | `go test ./...` 语义契约 13/13（测试机复核通过）；夹具可复用于换引擎验收；定稿待真实订阅逐类核对 |
| M1 | Windows CLI MVP（docs/tech/03 §8） | 🔶 长稳待授权 | dragnet-tun 六要素实测全通（DNS 劫持/真实IP映射/SNI 嗅探/urlfilter/REJECT/命中日志含 process=）；泄漏修复后 3 分钟采样内存趋平（~2.26GB，量级偏大待浸泡确认）；30min 长稳浸泡按用户要求暂停 |

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

### 测试机验证记录（2026-10-25，round1-4，日志 build/p0w-test/*.log 不入库）

**清单通过项（round1/2/3 实测证据）**：
- 出站绑定物理网卡 ✓（"出站绑定: 以太网 (index 15)"，防回环生效，全局路由下普通出网正常）
- DNS 劫持 ✓：命中规则域名回 NXDOMAIN（www.bilibili.com 测试规则 4 连击；dig.bdurl.net/dns.weixin.qq.com.cn→anti-AD；h5log-api-dualstack.mihoyo.com→hagezi；mobile.events.data.microsoft.com→AWAvenue）；正常域名转发解析（www.baidu.com→110.242.x.x）
- SNI 阻断 ✓：`curl --resolve www.bilibili.com:443:<真实CDN IP>` → 阻断 TCP + RST，日志含 `domain= process= rule= list=`（round3，绕过 DNS 的强证据路径验证）
- 进程识别 ✓：`process= Weixin.exe / curl.exe / clash-win64.exe`（iphlpapi 反查在真实流量上工作；PID 端口字节序疑点未见异常）
- 真实环境命中样本：微信 `dns.weixin.qq.com.cn`（TCP:8080）、百度 `dig.bdurl.net`、米哈游遥测 `h5log-api/apm-log-upload/sdk-log-upload.mihoyo.com`、微软遥测 `mobile.events.data.microsoft.com`；@@ 例外正常（www.msftconnecttest.com → ALLOW list=anti-AD，联网探测不被误杀）
- 退出清理 ✓：taskkill /F 强杀后 Dragnet 适配器移除、172.19 默认路由消失、系统 DNS 回 192.168.1.1、出网恢复（round2-A/round3-H 两次验证；WFP 规则随进程撤销符合设计注释）

**🔴 缺陷 1（已修复）DNS payload use-after-free**：sing-tun gVisor 路径传给 `NewDNSPacket` 的 payload 是内部包缓冲视图（`stack_gvisor_udp.go` 的 `view.AsSlice`），回调返回即回收复用；原实现直接丢进 goroutine 异步解析 → 随机读到被覆写数据。现象：每分钟十余条"DNS 解析失败: unpacking Question..."WARN、nslookup 首查 2s 超时。修复：回调内同步拷贝后再异步处理（tunstack.go）。round3 验证：WARN 17→0。
**🔴 缺陷 2（已修复）UDP 会话泄漏 ≈500MB/min**：`NewPacketConnectionEx` 等两个方向 goroutine 都自然结束，但出站 socket 无 deadline——服务器静默+客户端已亡时 `pc.ReadFrom` 永久阻塞，每条会话泄漏 socket+2 goroutine+64KB 缓冲。实测（round1）：5 分钟工作集 1.88GB→3.36GB 持续增长。修复：任一方向结束即关闭两端套接字。round3：3 分钟 2.26GB 后趋平（gVisor UDPTimeout=5min 的会话池稳态，量级仍偏大，长稳观察，M2 可优化缓冲策略）。
**🔴 缺陷 3（已修复）TCP 会话滞留**：`relay()` 同样无限等双向结束；静默对端可长期挂住会话。修复：服务器向 EOF 即关双端；客户端向 EOF 半关闭出站+30s 宽限后强制回收。
**🔴 缺陷 4（非内核 bug，测试方法+产品卫生）**："广告域名 nslookup 返回 0.0.0.0 而非 NXDOMAIN"（round1-4 复现）定位为 **Windows DNS 客户端缓存**：TUN 上线前解析过的域名（含 ISP 毒化应答 0.0.0.0/::）留在系统缓存，之后查询直接命中缓存、报文不进 TUN（round4 -v 判定日志证实：37 条判定无 pagead2，仅其 PTR 探测到达；黑洞服务器 192.0.2.1 实验 4ms 返回缓存实锤）。修复：dragnet-tun 启动时调用 `DnsFlushResolverCache` 刷新系统缓存；**测试规程：验证 DNS 拦截前必须 `ipconfig /flushdns`**（round5 起生效）。
**新增可观测性**：tunstack 每次 DNS 判定输出 Debug 日志（qname/action/list/dst），`-v` 开启；解析失败 WARN 带 src/dst/hex 头。Logger 接口增加 Debug（Windows/Android 适配器均已实现）。

**环境备注（测试机）**：Go 1.27.3（C:\Users\sytki\tools\go，GOPROXY=goproxy.cn）；Android SDK+NDK r30+Gradle 8.13 已装（C:\Users\sytki\tools\{android-sdk,gradle-8.13}，JDK 用 Liberica 17；dl.google.com 需钉 IP 180.163.150.161，Maven 走 ~/.gradle/init.d/cn-mirrors.init.gradle 的 aliyun 镜像）；无 Android 真机（adb 37.0.1 就绪）；GitHub raw 可直连；anti-ad.net 被 Cloudflare 限速不可用；本机代理 clash 127.0.0.1:7890 可用；管理员测试经 UAC 提权跑 build/p0w-test/round*.sh 自动化脚本（不入库）。

**round5 中断记录（2026-10-25 16:10，用户叫停，浸泡未开始）**：启动确认——规则引擎 277146 行就绪、出站绑定以太网(15)、"已刷新系统 DNS 缓存"日志出现（DnsFlushResolverCache 生效实证）、TUN 上线；终验异常——pagead2/doubleclick/google-analytics 均瞬时返回 0.0.0.0+::（无"阻断 DNS"日志），对照 baidu 正常、HTTP 200 正常；疑点定性见"当前状态"⚠️（多 DNS 竞速假说待取证）。中断后恢复核验全过（进程/适配器/路由/DNS/外网五项）。
**P0-A 构建侧记录（测试机，无需真机部分全过）**：.so 双 ABI 产出（arm64-v8a 10.5MB / x86_64 11.1MB），llvm-nm 导出=开发机核对集（DragnetLoadRules/DragnetMatchDetail/DragnetFreeString + Java_com_dragnet_app_DragnetNative_nativeSetService/nativeStartVpn/nativeStopVpn）；APK badging：com.dragnet.app v0.1-poc，compileSdk 36/minSdk 24/targetSdk 29，双 ABI .so 字节与构建产物一致；stripDebug 提示"Unable to strip libdragnet.so"属预期（Go 侧已 -s -w）。真机清单（android/README.md 4 步）🔶 待手机。

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

- 2026-10-25（测试机，第二次回写）：P0-A 构建侧在测试机复现通过：官方源钉 IP（dl.google.com 本机 DNS 给的 CDN 节点不通，改 --resolve 180.163.150.161）下载 NDK r30/platform-36/build-tools 35+36/platform-tools r37.0.1/cmdline-tools（布局 C:\Users\sytki\tools\android-sdk，licenses 已写入）+ Gradle 8.13（直连 services.gradle.org）；build-android.sh 交叉编译双 ABI .so（llvm-nm 核对 Dragnet*3+Java_*3 导出）；gradle assembleDebug（JDK17 + 用户级 init 脚本注入 aliyun google/public 镜像，不改仓库文件）1m02s 成功，APK 22.4MB，lib/{arm64-v8a,x86_64}/libdragnet.so 与修复版字节一致。真机验证 🔶（无手机；本机 DevEco 鸿蒙模拟器非 AOSP 不可用）。round5（NXDOMAIN 终验+30min 长稳）被用户叫停：确立"测试机授权规程"（接管网络必须先征得同意）；中断后已全面核验网络恢复（无进程/无适配器/路由 DNS 复原/外网通）。round5 中断前数据：内核启动自动清缓存日志确认生效；毒化广告域 0.0.0.0 应答疑点未决（见"当前状态"⚠️）。.gitignore 补充 .gradle/、local.properties。
- 2026-10-25（测试机）：首轮验证完成：基线（build/vet/test/with_gvisor）全绿；rulebench 3 表 27.7 万行构建 226ms/堆 47.9MB/33-36 万 QPS；dragnetctl 13/13+stdin 冒烟过。P0-W round1-4（UAC 提权自动化脚本）：清单 1/2/4/5 项通过，DNS/SNI/进程识别/清理恢复全实证；修复 3 内核缺陷（DNS payload use-after-free 同步拷贝、UDP 会话泄漏 ≈500MB/min、TCP relay 滞留）+ 启动刷新系统 DNS 缓存（DnsFlushResolverCache）+ DNS 判定 Debug 日志（-v）；"pagead2 漏封"定性为 Windows DNS 缓存假象（非 bug，黑洞服务器实验实锤），测试规程补 flushdns。gofmt 全净（顺手修了 main.go 一处 import 序）。待办：round5 NXDOMAIN 终验+30min 长稳；P0-A 工具链搭建中（无真机 🔶）。
- 2026-10-24（六）：P0-A 完成（开发机侧）：架构重构抽出 internal/tunstack 平台无关处理链（Windows CLI 与 Android 内核共用，两端语义一致）；cmd/dragnetvpn Android 内核（JNI：VpnService fd + protect 防回环 + 全套规则 C ABI 导出，dragnetlib 并入）；android/ 薄壳工程（VpnService+程序化 UI，零第三方依赖）；本机 Gradle 8.13+JBR21 assembleDebug 实测通过，APK 22.4MB 双 ABI。全量回归：build（默认+with_gvisor）+vet+test 4 包 + 自检 13/13。**开发机待办清空，阻塞于测试进度**。
- 2026-10-24（五）：M1 代码侧收口：dragnet-tun 内置种子规则（internal/blocklist，go:embed 开箱即用，无订阅目录也可运行）+ 长稳加固（DNS/TCP/UDP 全部回调加 panic 边界，分钟级运行统计：dns/tcp/udp 阻断与中继计数、缓存规模）；M0-3 语义测试集 9→13 条（反向 important 例外、v6 hosts、$dnsrewrite 忽略、大写+尾点归一化），自检输出改动态计数。`go build`（默认+with_gvisor）+`go vet`+`go test` 全过，自检 13/13。规则加载器抽出 LoadRules 内存入口（C ABI 与内置规则共用）。
- 2026-10-24（四）：P0-W 完成（dragnet-tun：sing-tun gVisor 栈 + JudgeFlow 流级阻断 + DNS 劫持 NXDOMAIN + SNI/HTTP Host 嗅探 + ipcache 有界 IP↔域名缓存 + iphlpapi 进程反查，出站绑定物理网卡防回环）；P0-A 编译件完成（dragnetlib C ABI：线程/所有权/崩溃契约，scripts/build-android.sh 产出 arm64-v8a+x86_64 .so，导出已用 llvm-nm 核对）；M0-2 威胁模型初稿（docs/tech/04，源机器）。`go build`（默认+with_gvisor tag）+`go vet`+`go test` 全过；无管理员冒烟：规则加载与出站网卡判定正常，卡 TUN 创建（符合预期）。语义自检 9/9。
- 2026-10-24（三）：D-1~D-4 完成（verdict 契约包 / engine 接口 / urlfilter 适配器 / 原子切换加载器 / rulebench / dragnetctl / fetch-rules 脚本 / 语义测试集）。`go build`+`go vet`+`go test` 全过；本机零特权冒烟：3 表 27.7 万行构建 950ms、堆 47.5MB、65k QPS、语义自检 9/9。待测试机复核基准与长期运行。
- 2026-10-24（二）：确立双机工作流（开发机=编译通过即验收，测试机=运行调试）；demo 范围定为 D-1~D-4+P0-W 编译件；开工 D-1/D-2/D-3/D-4。
- 2026-10-24（一）：技术选型批准并经评审修订（过程见源机器 docs/tech/01-03）；建立本看板；源机器完成环境准备（Go/Android SDK/DevEco）。
