import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_scope.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 设置页（对齐鸿蒙 SettingsPage）：玻璃质感 / 主题 / 规则目录 / 关于。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    final cs = Theme.of(context).colorScheme;
    return GlassHeaderOverlay(
      title: '设置',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
        children: [
          // ── 玻璃质感 ──────────────────────────────────────────────────
          ContentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 20, color: cs.primary),
                    const SizedBox(width: 8),
                    Text('玻璃质感',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('液态：真折射透镜（Impeller）；Material：自洽 M3 材质',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                _GlassModeSegmented(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── 外观 ──────────────────────────────────────────────────────
          ContentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.dark_mode_outlined,
                        size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('主题',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final (i, mode) in const [
                      (ThemeMode.system, '跟随系统'),
                      (ThemeMode.light, '浅色'),
                      (ThemeMode.dark, '深色'),
                    ].indexed)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                          child: _ThemeChip(
                            label: mode.$2,
                            selected: _themeMode == mode.$1,
                            onTap: () => setState(() => _themeMode = mode.$1),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── 关于 ──────────────────────────────────────────────────────
          ContentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('罗网 Dragnet',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  '免证书的域名与连接级广告、跟踪器拦截。\n'
                  'Go 统一内核（libdragnet.so）+ Flutter 薄壳；'
                  '整机 GPL-3.0。\n'
                  'v1.0.0+1 · 包名 com.march.dragnet_app',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                      height: 1.6),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _GlassModeSegmented extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final liquid = GlassMaterialScope.of(context) == GlassMaterialMode.liquid;
    // 分段控件（指南 §10 简版）：高亮块 AnimatedPositioned 200ms easeOutCubic
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      const items = ['液态', 'Material'];
      return GlassSurface(
        height: 40,
        padding: const EdgeInsets.all(4),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: GlassTokens.motionDuration,
              curve: GlassTokens.motionCurve,
              left: liquid ? 0 : w / 2 - 4,
              top: 0,
              width: w / 2 - 4,
              height: 32,
              child: Container(
                decoration: BoxDecoration(
                  color: GlassTokens.selectedHighlight(cs),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            Row(
              children: [
                for (final (i, label) in items.indexed)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => glassMaterialMode.value =
                          i == 0 ? GlassMaterialMode.liquid : GlassMaterialMode.material,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: GlassTokens.motionDuration,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: (i == 0) == liquid
                                ? cs.onSurface
                                : cs.onSurfaceVariant,
                          ),
                          child: Text(label),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GlassSurface(
      height: 40,
      onTap: onTap,
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
