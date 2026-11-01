# flutter_app/ — 罗网 Android 正式壳（Flutter + 液态玻璃）

PoC 单页（仓库根 `android/`，Kotlin 程序化 UI）升级为正式四 Tab UI：
**首页仪表盘 / 统计 / 规则 / 设置 + 匹配自检子页**，设计语言按
《液态玻璃UI复现指南》（LoveIwara 0.6.1 提炼版，源机器 `C:\Data\液态玻璃UI复现指南.md`）实现。

## 结构

```
lib/
  main.dart                 启动：shader 预热 + GlassMaterialScope + 主题（深青种子色）
  design/                   液态玻璃设计系统（指南 §3/§4/§6/§7/§9/§11/§12 落地）
    glass_tokens.dart       唯一参数源（尺寸/动效/颜色/液态参数）
    glass_scope.dart        GlassBackend 四档 + 全局玻璃质感开关 + 三个供档点
    glass_surface.dart      GlassSurface 四档材质收口 + GlassPressable + 挖洞画影
    edge_fade_scrim.dart    渐进蒙层（smoothstep 16 段，无 BackdropFilter）
    glass_reveal.dart       GlassReveal / ScrollActivityMonitor / 回顶浮钮
    glass_header.dart       GlassHeaderOverlay（单胶囊收口 header 行）
    glass_menu.dart         showGlassMenu（卷开出入场 + 条目错峰）
    glass_dialog.dart       showAppDialog 双通道过渡 + 弹窗/底板族
  pages/home_shell.dart     悬浮底栏壳（Stack 覆盖层 + 落地时机状态机 + Material 档自绘）
  pages/*.dart              五页面（对齐鸿蒙端功能面）
  state/app_controller.dart dragnet/native MethodChannel 桥 + 2s 轮询
android/.../com/dragnet/app/    JNI 桥（⚠️ 包名类名固定，JNI 符号按此生成）
android/.../com/march/dragnet_app/MainActivity.kt  FlutterActivity + MethodChannel
```

## 依赖（钉死版本，指南标定）

- `liquid_glass_easy: 4.1.1`（真折射透镜，浮出面板档）——5.x 重构 API 未标定，勿盲升
- `liquid_glass_widgets: 0.30.2`（页面 chrome：GlassTabBar.bottom 等 0.x API 线）
- `dynamic_color`（系统动态取色；无动态色时回落深青种子）

## 构建与安装

前置：Go 内核 .so 先产出（Gradle jniLibs 直接引用 `build/android/<abi>/`）：

```bash
bash scripts/build-android.sh        # 仓库根执行，产出 build/android/arm64-v8a|x86_64/libdragnet.so
```

Flutter 构建（本机 Flutter 3.47.9 装于 C:\Data\tools\flutter；JDK 用 DevEco JBR）：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
flutter analyze                       # 应零问题
flutter test                          # 冒烟：mock 通道渲染四 Tab
flutter build apk --debug             # 产物 build/app/outputs/flutter-apk/app-debug.apk
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

走代理时：`flutter_app/android/gradle.properties` 末尾已含 127.0.0.1:7890 的
systemProp 四行；**无代理环境（如测试机直连）删除或按需改端口**。
JDK 配置：`flutter config --jdk-dir "C:\Program Files\Huawei\DevEco Studio\jbr"`。

## 与 PoC 壳（根 android/）的关系

- 包名不同：本壳 `com.march.dragnet_app`，PoC 壳 `com.dragnet.app`，可共存对照。
- JNI 类固定 `com.dragnet.app.DragnetNative`（符号 Java_com_dragnet_app_* 已固化，
  含本次新增的 nativeRuleInfo / nativeMatch，见 cmd/dragnetvpn/main.go）。
- targetSdk=29 沿用 PoC 口径（免 foregroundServiceType 合规），M4 再升。

## 已知 v1 裁剪（记录于 PROGRESS.md）

- header 行用"单只玻璃胶囊收三段"（1 次 backdrop 采样）；多块玻璃
  AdaptiveLiquidGlassLayer 融合留 v2。
- 跟手形变（LiquidStretch/GlassButton.custom 借形变+约束信使）留 v2；
  按压反馈走 scale 0.96 + 底色加深。
- showGlassMenu 的"滑动取焦/手指接力"留 v2；卷开出入场已实现。
- 菜单当前无实际调用点（五页面均为直达交互），作为设计系统组件入库备用。
