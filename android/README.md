# android/ — 罗网 Android 薄壳（P0-A）

零第三方依赖的 VpnService 最小链路 PoC：Kotlin 只做授权、establish 拿 fd、
起停内核；全部拦截逻辑在 `build/android/<abi>/libdragnet.so`（Go 内核，
`scripts/build-android.sh` 产出，Gradle 直接以 jniLibs 引用）。

## 构建与安装

```bash
bash scripts/build-android.sh        # 先产出内核 .so（build/android/<abi>/）
cd android
gradle assembleDebug                  # 需 Gradle ≥8.11 + JDK 17+ + AGP 联网
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Gradle/AGP 走代理时在命令行追加：
`-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890`

## 验证（真机/模拟器）

1. 安装启动，点"启动拦截"→ 授权 VPN。
2. `adb logcat -s Dragnet` 应出现 `nativeStartVpn(...) = 0` 与内核"上线"日志。
3. 浏览器访问 `doubleclick.net` 等种子规则域名 → 请求失败（DNS NXDOMAIN）；
   普通网站正常；`logcat` 出现"阻断 DNS ..."。
4. 点"停止拦截"→ `nativeStopVpn = 0`，网络恢复正常。

已知限制（PoC 范围）：仅 IPv4；规则=内置种子（外部订阅走 DragnetLoadRules，
壳未接）；无通知栏服务（targetSdk 29 下可接受，息屏可能被杀——长稳在 M2 验证）。
