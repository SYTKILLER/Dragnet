import 'package:flutter/material.dart';

import '../services/rule_source.dart';
import 'app_controller.dart';

/// 全局主题模式（对齐 glassMaterialMode 的全局开关口径）。
/// ⛔ 之前 SettingsPage 的 _themeMode 是页面局部 state、main.dart 写死
/// ThemeMode.system，浅色/深色点了不生效——改这里单一参数源 + 持久化
/// （config/theme-mode.txt，落盘口径同 dns-up.txt）。
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.system);

String _encode(ThemeMode m) => switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };

ThemeMode _decode(String s) => switch (s.trim()) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// 冷启动恢复持久化值（main 里 fire-and-forget）。rulesDir 尚未取到时先
/// 等一次 refreshRuleInfo（单次通道调用）；全程失败保持 system 不阻塞启动。
Future<void> loadAppThemeMode() async {
  try {
    final controller = AppController.instance;
    if (controller.rulesDir.isEmpty) await controller.refreshRuleInfo();
    final svc = SubscriptionService.instance;
    await svc.ensureLoaded(controller.rulesDir);
    appThemeMode.value = _decode(await svc.readThemeMode());
  } catch (_) {
    // 桥不可用/测试环境：保持默认
  }
}

/// 设置页点选：先改内存（即时生效）再落盘（下次启动恢复）。
Future<void> saveAppThemeMode(ThemeMode mode) async {
  appThemeMode.value = mode;
  await SubscriptionService.instance.writeThemeMode(_encode(mode));
}
