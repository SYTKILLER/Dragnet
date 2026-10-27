# ohos/ — 罗网 HarmonyOS 薄壳（P0-H）

三方 VPN（`VpnExtensionAbility` + `@ohos.net.vpnExtension`）最小链路 PoC：
ArkTS 只做四件事——create 拿 tun fd、注册 protect 回调、分发种子规则、起停
内核；全部拦截逻辑在 `build/ohos/<abi>/libdragnet.so`（Go 内核，Go NAPI 模块
本体，与 Windows/Android 共用 `internal/tunstack`，三端语义一致）。

## 构成

- `entry/src/main/ets/vpnability/VpnExtAbility.ets`：三方 VPN 扩展。onCreate →
  `loadRules(filesDir/rules)` → `VpnConnection.create()` → `startVpn(tunFd,...)`；
  出站防回环走 protect 回握协议（内核 tsfn 通知 JS(id,fd) → JS 调
  `VpnConnection.protect(fd)` → `setProtected(id)` 回握，5s 超时放弃拨号）。
- `entry/src/main/ets/pages/Index.ets`：起停/统计/匹配自检 UI。
- `entry/src/main/ets/types/libdragnet.d.ts`：libdragnet.so 类型声明。
- `entry/libs/x86_64/libdragnet.so`：构建时从 `build/ohos/` 拷入（不入库）。
- 种子规则经 rawfile 分发（EntryAbility 启动时拷到 filesDir/rules，已有不
  覆盖——M4-R1 可见性合规：随分发包的可见文件，非内嵌二进制）。

## 工具链（首次准备，一次性的）

1. **ohos-go 编译器**（golang/go fork，`GOOS=openharmony`，含 x86_64 c-shared
   的 TLS descriptor/global-dynamic 支持）：
   ```bash
   git clone --depth 1 https://github.com/sysit/ohos-go /d/research/ohos-go
   cd /d/research/ohos-go/src
   cmd //c "cd /d D:\research\ohos-go\src && set GOROOT_BOOTSTRAP=<本机Go>&& make.bat"
   ```
   为什么必须：上游 Go 的 c-shared 在 linux/amd64 用 initial-exec TLS 重定位
   （R_X86_64_TPOFF64），OHOS musl 加载器 dlopen 时直接拒绝
   （`initial-exec TLS resolves to dynamic definition`）。该 fork 在
   GOOS=openharmony + shared 下自动改用 TLS descriptor（asm6.go
   isOpenharmony 分支）。GOOS=openharmony 同时满足 `linux` 构建标签，
   sing-tun/gvisor 无需改动直接编译。
2. **OHOS 原生工具链**：DevEco Studio 自带
   `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native`。
3. **签名材料**：本机 DevEco 已有华为账号自动签名产物（`~/.ohos/config`）；
   复用既有工程（如 D:\HarmonyOS_Develop\Cimoc）的 debug 签名块注入
   build-profile.json5（bundleName 须与 profile 匹配 → 本工程临时用
   `com.march.cimoc`；正式 bundle 建成后在 DevEco 里自动签名一次替换）。
   签名块含本机加密口令，不入库（仓库内 build-profile.json5 的
   signingConfigs 保持空）。

## 构建与安装

```bash
bash scripts/build-ohos.sh          # 交叉编译 libdragnet.so（x86_64，模拟器架构）
bash scripts/build-ohos-hap.sh      # 拷 .so+rawfile → 注入签名 → devecocli build → 安装
# 或手动：
cp build/ohos/x86_64/libdragnet.so ohos/entry/libs/x86_64/
cp rules/starter.txt rules/protected-allow.txt ohos/entry/src/main/resources/rawfile/rules/
cd ohos && devecocli build
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

## 验证（模拟器，虚拟设备零接触宿主机网络）

⚠️ **已定性环境限制**（2026-10-27，本机 5 个镜像全测）：DevEco 模拟器镜像
**不含系统 VPN 授权对话框应用 com.huawei.hmos.vpndialog**，首次信任授权
（settingsdata 的 vpnext_mode 行）无法授予 → `VpnConnection.create` 被拒
（"Non-system applications use system APIs"）。**真机不受影响**。

可验证（已在 AVD `Pura 90`[x86_64/API24] 实测通过）：

1. 安装启动 → hilog 出现种子分发
   `seed starter.txt -> .../files/rules/starter.txt`。
2. UI"匹配自检"→ 返回引擎判定（UI 进程实例空载 NOMATCH 属预期，规则在
   VPN 进程加载）。
3. `hdc shell aa start -a VpnExtAbility -b com.march.cimoc` 直启扩展（模拟器
   绕行路径；真机走 UI 按钮+系统授权对话框）→ hilog：
   `[Dragnet] loadRules(.../files/rules) = 0`（内核 NAPI+引擎+规则全通）
   及 `VpnConnection.create failed: ...`（信任门槛，真机不出现）。
4. 真机完整链路（待验证）：点"启动拦截"→系统授权对话框"允许"→
   `VpnConnection.create -> tunFd=N` → `startVpn = 0` → 状态栏钥匙图标 →
   广告域 NXDOMAIN / 正常域通 → 点"停止拦截"恢复。

## 已知限制（PoC 范围）

- 模拟器信任门槛（见上）；仅 x86_64 ABI（真机 arm64 加一行 build_one 即可，
  待签名后验证）；
- VPN 扩展进程 hilog JS API 的 accessToken IPC 在模拟器失败（日志静默丢
  弃），壳内改用 console.info（JSAPP 通道）；
- NAPI 模块名警告 `Name mismatch: default/dragnet != default/napiGoOH`
  （ohos-napi 库固定注册名，ClashBox 同款，不影响功能）；
- 外部规则=rawfile 种子分发（订阅下载 M3 已在 Windows 侧实现，ohos 侧接入
  排期中）。
