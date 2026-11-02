import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_meta.dart';
import '../design/glass_dialog.dart';
import '../design/glass_header.dart';
import '../design/glass_scope.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../services/app_update.dart';
import '../services/rule_source.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 设置页（对齐鸿蒙 SettingsPage）：玻璃质感 / 主题 / 更新（App + 规则）/
/// 规则自动更新开关 / 关于。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _checkingApp = false;
  bool _checkingRules = false;
  bool _autoRules = true;

  SubscriptionService get _svc => SubscriptionService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfig());
  }

  Future<void> _loadConfig() async {
    await _svc.ensureLoaded(widget.controller.rulesDir);
    if (!mounted) return;
    setState(() => _autoRules = _svc.appConfig.autoUpdateRules);
  }

  void _snack(String msg) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg),
          width: 360,
          behavior: SnackBarBehavior.floating));
  }

  // ── App 自更新检查 ────────────────────────────────────────────────────────

  Future<void> _checkAppUpdate() async {
    if (_checkingApp) return;
    setState(() => _checkingApp = true);
    final r = await checkAppUpdate();
    if (!mounted) return;
    setState(() => _checkingApp = false);
    switch (r.status) {
      case AppUpdateStatus.error:
        _snack('检查失败：${r.message}');
      case AppUpdateStatus.upToDate:
        AppUpdateNotifier.instance.clear();
        await showAppDialog(
          context,
          builder: (ctx) => GlassAlertDialog(
            title: '检查更新',
            content: Text('已是最新版本（v$appVersion）。',
                style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(ctx).colorScheme.onSurface)),
            actions: [
              GlassDialogAction('好',
                  emphasized: true,
                  onPressed: () =>
                      Navigator.of(ctx, rootNavigator: true).pop()),
            ],
          ),
        );
      case AppUpdateStatus.available:
        if (r.release != null) await _showUpdateDialog(r.release!);
    }
  }

  Future<void> _showUpdateDialog(AppRelease rel) async {
    AppUpdateNotifier.instance.clear();
    await showAppDialog(
      context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final urlCtrl = TextEditingController(text: rel.downloadUrl);
        return GlassAlertDialog(
          title: '发现新版本 ${rel.tag}',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rel.notes.trim().isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Text(
                      summarizeNotes(rel.notes),
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: cs.onSurface,
                          fontFamily: 'monospace'),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text('下载地址',
                  style: TextStyle(
                      fontSize: 12.5, color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: urlCtrl,
                      readOnly: true,
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassSurface(
                    circle: true,
                    height: 40,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: urlCtrl.text));
                      _snack('已复制下载链接');
                    },
                    child: Icon(Icons.copy_outlined,
                        size: 18, color: cs.onSurface),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            GlassDialogAction('关闭',
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop()),
            GlassDialogAction(
              '复制链接',
              emphasized: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: urlCtrl.text));
                _snack('已复制下载链接');
              },
            ),
          ],
        );
      },
    );
  }

  // ── 规则更新 ─────────────────────────────────────────────────────────────

  Future<void> _checkRulesNow() async {
    if (_checkingRules) return;
    setState(() => _checkingRules = true);
    try {
      final summary = await widget.controller.updateAllSources();
      if (!mounted) return;
      final msg = StringBuffer('规则检查：更新 ${summary.updated}'
          ' · 跳过 ${summary.skipped} · 失败 ${summary.failed}');
      if (summary.warnings.isNotEmpty) {
        msg.write('；⚠ ${summary.warnings.join('；')}');
      }
      _snack(msg.toString());
    } finally {
      if (mounted) setState(() => _checkingRules = false);
    }
  }

  Future<void> _toggleAutoRules(bool v) async {
    setState(() => _autoRules = v);
    await _svc.saveAppConfig(autoUpdateRules: v);
  }

  // ── UI ───────────────────────────────────────────────────────────────────

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
          // ── 更新 ─────────────────────────────────────────────────────
          ContentCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                // 检查更新（静默检查命中后这里带角标）
                AnimatedBuilder(
                  animation: AppUpdateNotifier.instance,
                  builder: (context, _) {
                    final n = AppUpdateNotifier.instance;
                    return _SettingsRow(
                      icon: Icons.system_update_outlined,
                      title: '检查更新',
                      subtitle: n.updateAvailable
                          ? '有新版本 ${n.release?.tag ?? ''}'
                          : 'GitHub Releases（app-v*）',
                      badge: n.updateAvailable,
                      trailing: _checkingApp
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.2))
                          : Icon(Icons.chevron_right,
                              size: 22, color: cs.onSurfaceVariant),
                      onTap: _checkingApp ? null : _checkAppUpdate,
                    );
                  },
                ),
                const Divider(height: 1),
                _SettingsRow(
                  icon: Icons.info_outline,
                  title: '当前版本',
                  subtitle: 'v$appVersion+$appBuild · 包名 com.march.dragnet_app',
                  trailing: null,
                ),
                const Divider(height: 1),
                _SettingsRow(
                  icon: Icons.autorenew_outlined,
                  title: '规则自动更新',
                  subtitle: '启动时与每 6 小时静默检查一次订阅源',
                  trailing: Switch(
                    value: _autoRules,
                    onChanged: (v) => unawaited(_toggleAutoRules(v)),
                  ),
                ),
                const Divider(height: 1),
                _SettingsRow(
                  icon: Icons.cloud_download_outlined,
                  title: '立即检查规则更新',
                  subtitle: '顺序拉取全部启用源并热切换',
                  trailing: _checkingRules
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2))
                      : Icon(Icons.chevron_right,
                          size: 22, color: cs.onSurfaceVariant),
                  onTap: _checkingRules ? null : _checkRulesNow,
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
                  '整机 GPL-3.0。',
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

/// 设置行：图标 + 标题/副标题 + 尾部（可带角标红点）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.badge = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                  ),
                  if (badge) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 8,
                      height: 8,
                      decoration:
                          BoxDecoration(color: cs.error, shape: BoxShape.circle),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                            fontSize: 11.5, color: cs.onSurfaceVariant)),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _GlassModeSegmented extends StatelessWidget {
  const _GlassModeSegmented();

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
