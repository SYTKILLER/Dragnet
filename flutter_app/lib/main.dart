import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

import 'design/glass_reveal.dart';
import 'design/glass_scope.dart';
import 'pages/home_shell.dart';
import 'pages/dashboard_page.dart';
import 'pages/match_test_page.dart';
import 'pages/rules_page.dart';
import 'pages/settings_page.dart';
import 'pages/stats_page.dart';
import 'state/app_controller.dart';

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
            return MaterialApp(
              title: '罗网 Dragnet',
              debugShowCheckedModeBanner: false,
              themeMode: ThemeMode.system,
              theme: _theme(lightScheme),
              darkTheme: _theme(darkScheme),
              home: const _Home(),
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

class _Home extends StatelessWidget {
  const _Home();

  void _openMatchTest(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MatchTestPage(controller: AppController.instance),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppController.instance;
    return HomeShell(
      tabs: const ['首页', '统计', '规则', '设置'],
      extraLabel: '自检',
      extraIcon: Icons.fact_check_outlined,
      extraOnTap: () => _openMatchTest(context),
      pages: [
        DashboardPage(controller: controller),
        StatsPage(controller: controller),
        RulesPage(controller: controller),
        SettingsPage(controller: controller),
      ],
    );
  }
}
