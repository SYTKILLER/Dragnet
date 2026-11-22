import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

import 'design/glass_reveal.dart';
import 'design/glass_scope.dart';
import 'pages/home_shell.dart';
import 'pages/dashboard_page.dart';
import 'pages/logs_page.dart';
import 'pages/rules_page.dart';
import 'pages/settings_page.dart';
import 'state/app_controller.dart';
import 'state/theme.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // ⭐ shader 预热（fire-and-forget）：不预热的话冷启动首屏第一块玻璃先
    // 渲染成磨砂、shader 异步加载完再切成折射——肉眼可见的材质跳变。
    if (glassMaterialMode.value == GlassMaterialMode.liquid) {
      unawaited(warmUpLiquidGlassShaders());
    }
    final controller = AppController.instance;
    unawaited(controller.refreshStats());
    unawaited(controller.refreshRuleInfo());
    controller.startPolling();
    // 方向1：种子规则写入 + 订阅 6h / App 24h 自动检查（内部全程 try/catch 静默）
    unawaited(controller.startBackgroundServices());
    // 主题模式冷启动恢复（持久化于 config/theme-mode.txt，失败保持 system）
    unawaited(loadAppThemeMode());
    runApp(const DragnetApp());
  }, (error, stack) {
    debugPrint('未捕获异常: $error\n$stack');
  });
}

Future<void> warmUpLiquidGlassShaders() async {
  try {
    await LiquidGlassShaders.ensureLoaded();
  } catch (_) {}
  try {
    // ⛔ enablePerformanceMonitor: false：监视器在 debug/profile 盯光栅耗时
    // 超预算就抛 FlutterError，本应用同屏常有转发负载，几乎必然误报。
    await lgw.LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  } catch (_) {}
}

/// 主题种子色：深青（对齐鸿蒙端主色口径）。
const _seedColor = Color(0xFF00696E);

class DragnetApp extends StatelessWidget {
  const DragnetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassMaterialScope(
      child: NotificationListener<ScrollNotification>(
        onNotification: ScrollActivityMonitor.instance.handle,
        child: DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final lightScheme = lightDynamic ??
                ColorScheme.fromSeed(seedColor: _seedColor);
            final darkScheme = darkDynamic ??
                ColorScheme.fromSeed(
                    seedColor: _seedColor, brightness: Brightness.dark);
            // 主题模式走全局 notifier（设置页点选即时生效并持久化）
            return ValueListenableBuilder<ThemeMode>(
              valueListenable: appThemeMode,
              builder: (context, mode, _) => MaterialApp(
                title: '罗网 Dragnet',
                debugShowCheckedModeBanner: false,
                themeMode: mode,
                theme: _theme(lightScheme),
                darkTheme: _theme(darkScheme),
                home: const _Home(),
              ),
            );
          },
        ),
      ),
    );
  }

  ThemeData _theme(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // ⛔ 触屏关长按 tooltip：玻璃手感全建立在"按住不放"上（500ms 后会弹
      // 黑条并判 tap 负）。主题钉死，所有 Tooltip 的共同上游。
      tooltipTheme: const TooltipThemeData(
          triggerMode: TooltipTriggerMode.manual),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 一级 Tab：首页 / 日志 / 规则 / 设置。统计页内容与首页完全重复（运行时
/// 8 项计数），按 2026-11-22 UI 评审口径撤下独立 Tab，把高频的转发日志
/// 提升为一级页面；匹配自检属低频排障工具，只保留规则页一处入口，
/// 底栏右侧独立圆钮让位给全站任意 Tab 都顺手的一键启停。
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    final controller = AppController.instance;
    return HomeShell(
      tabs: const ['首页', '日志', '规则', '设置'],
      pages: [
        DashboardPage(controller: controller),
        LogsPage(controller: controller, tabIndex: 1),
        RulesPage(controller: controller),
        SettingsPage(controller: controller),
      ],
    );
  }
}
