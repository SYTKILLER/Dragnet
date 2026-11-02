import 'dart:async';

import 'package:flutter/material.dart';

import '../design/glass_dialog.dart';
import '../design/glass_header.dart';
import '../design/glass_menu.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../services/rule_source.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';
import 'logs_page.dart';
import 'match_test_page.dart';

/// 规则页（方向1 改造）：转发日志入口 + 规则规模（ruleInfo）+ 订阅源管理 +
/// 用户规则管理 + 重新加载 + 匹配自检入口 + 外部规则指引。
class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  bool _updatingAll = false;
  String _progress = '';
  bool _reloading = false;
  int _userRuleCount = 0;

  SubscriptionService get _svc => SubscriptionService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_svc.ensureLoaded(widget.controller.rulesDir));
    unawaited(_refreshUserRuleCount());
  }

  Future<void> _refreshUserRuleCount() async {
    final lines = await _svc.readUserRuleLines();
    if (!mounted) return;
    setState(() => _userRuleCount =
        parseUserRules(lines.join('\n')).where((e) => e.kind != UserRuleKind.other).length);
  }

  void _snack(String msg) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg),
          width: 360,
          behavior: SnackBarBehavior.floating));
  }

  // ── 全部更新（顺序逐源，UI 显示第 x/n 个）────────────────────────────────

  Future<void> _updateAll() async {
    if (_updatingAll) return;
    setState(() {
      _updatingAll = true;
      _progress = '';
    });
    try {
      final summary = await widget.controller.updateAllSources(
        onProgress: (done, total, name) {
          if (!mounted) return;
          setState(() {
            if (total == 0) {
              _progress = '无启用源';
            } else if (done < total) {
              _progress = '正在更新 ${done + 1}/$total · $name';
            } else {
              _progress = '';
            }
          });
        },
      );
      if (!mounted) return;
      final msg = StringBuffer('更新 ${summary.updated} · 跳过 ${summary.skipped}'
          ' · 失败 ${summary.failed}');
      if (summary.warnings.isNotEmpty) {
        msg.write('；⚠ ${summary.warnings.join('；')}');
      }
      _snack(msg.toString());
      await _refreshUserRuleCount();
    } finally {
      if (mounted) {
        setState(() {
          _updatingAll = false;
          _progress = '';
        });
      }
    }
  }

  // ── 单源操作 ─────────────────────────────────────────────────────────────

  Future<void> _updateOne(SourceConfig s) async {
    final r = await _svc.fetchOne(s);
    if (!mounted) return;
    switch (r.status) {
      case SourceFetchStatus.updated:
        final rc = await widget.controller.reloadRules();
        await widget.controller.refreshRuleInfo();
        if (!mounted) return;
        _snack('${s.name} 已更新 ${r.lines} 行'
            '${rc == 0 ? '，热切换 rc=0' : '，⚠ 热切换失败 rc=$rc'}'
            '${r.shrinkWarning ? '（⚠ 行数收缩>50%）' : ''}');
      case SourceFetchStatus.notModified:
        _snack('${s.name} 未变化（304）');
      case SourceFetchStatus.error:
        _snack('${s.name} 更新失败：${r.error}');
    }
    await _svc.saveAppConfig(lastRulesCheck: DateTime.now());
  }

  Future<void> _deleteSource(SourceConfig s) async {
    await _svc.deleteSource(s.id);
    final rc = await widget.controller.reloadRules();
    await widget.controller.refreshRuleInfo();
    if (!mounted) return;
    _snack(rc == 0
        ? '已删除 ${s.name} 并重载（rc=0）'
        : '已删除 ${s.name}，重载失败（rc=$rc）');
  }

  void _sourceMenu(BuildContext anchorContext, SourceConfig s) {
    unawaited(showGlassMenu(
      anchorContext,
      options: [
        GlassMenuOption(
          label: '立即更新',
          icon: Icons.download_outlined,
          onTap: () => unawaited(_updateOne(s)),
        ),
        GlassMenuOption(
          label: s.enabled ? '停用' : '启用',
          icon: s.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
          description: s.enabled ? '跳过自动/手动更新' : '恢复参与更新',
          onTap: () => unawaited(_svc.setEnabled(s.id, !s.enabled)),
        ),
        GlassMenuOption(
          label: '删除',
          icon: Icons.delete_outline,
          description: '移除配置与已下载规则文件',
          destructive: true,
          onTap: () => unawaited(_deleteSource(s)),
        ),
      ],
    ));
  }

  Future<void> _addSourceDialog() async {
    await showAppDialog(context, builder: (_) => const _AddSourceDialog());
  }

  // ── 用户规则 ─────────────────────────────────────────────────────────────

  Future<void> _openUserRules() async {
    await showGlassBottomSheet(
      context,
      title: '用户规则（zzz-user-rules.txt）',
      // 内部自管约束（ConstrainedBox+Flexible），不套 SingleChildScrollView
      scrollable: false,
      builder: (_) => _UserRulesSheet(controller: widget.controller),
    );
    await _refreshUserRuleCount();
    await widget.controller.refreshRuleInfo();
  }

  // ── 重新加载 ─────────────────────────────────────────────────────────────

  Future<void> _reload() async {
    if (_reloading) return;
    setState(() => _reloading = true);
    final rc = await widget.controller.reloadRules();
    await widget.controller.refreshRuleInfo();
    await _refreshUserRuleCount();
    if (!mounted) return;
    setState(() => _reloading = false);
    final info = widget.controller.ruleInfo;
    _snack(rc == 0
        ? '重载成功（rc=0）'
            '${info == null ? '' : '：${info.lists} 个列表 / ${info.ruleLines} 行'}'
        : '重载失败（rc=$rc）');
  }

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    final svc = _svc;
    return GlassHeaderOverlay(
      title: '规则',
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.controller, svc]),
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final info = widget.controller.ruleInfo;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
            children: [
              // ── 转发日志入口 ────────────────────────────────────────────
              ContentCard(
                onTap: () => unawaited(Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            LogsPage(controller: widget.controller)))),
                child: Row(
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        size: 22, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('转发日志',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text('内核 DNS/TCP/UDP 判定流水（增量轮询）',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 22, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // ── 已加载规则（ruleInfo）────────────────────────────────────
              if (info != null)
                ContentCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.rule_outlined,
                              size: 20, color: cs.primary),
                          const SizedBox(width: 8),
                          Text('已加载规则',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                              child: StatTile(
                                  label: '规则列表',
                                  value: '${info.lists}',
                                  valueColor: cs.primary)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: StatTile(
                                  label: '规则行', value: '${info.ruleLines}')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                              child: StatTile(
                                  label: '规则体积',
                                  value: formatBytes(info.ruleBytes))),
                        ],
                      ),
                    ],
                  ),
                )
              else
                const ContentCard(
                  child: Column(
                    children: [
                      SizedBox(height: 8),
                      EmptyState(
                        icon: Icons.rule_outlined,
                        title: '引擎空载',
                        subtitle: '未加载任何外部规则（fail-open，不拦截）',
                      ),
                      SizedBox(height: 8),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              // ── 订阅源 ──────────────────────────────────────────────────
              _SourcesCard(
                updatingAll: _updatingAll,
                progress: _progress,
                onUpdateAll: _updateAll,
                onAdd: _addSourceDialog,
                onSourceMenu: _sourceMenu,
                onUpdateOne: _updateOne,
              ),
              const SizedBox(height: 16),
              // ── 用户规则 ────────────────────────────────────────────────
              ContentCard(
                onTap: _openUserRules,
                child: Row(
                  children: [
                    Icon(Icons.edit_note_outlined,
                        size: 22, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('用户规则',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text(
                              '$_userRuleCount 条 · 拦截 ||域名^ / 放行 @@||域名^\$important',
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Text('管理',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
                    Icon(Icons.chevron_right,
                        size: 22, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // ── 重新加载 ────────────────────────────────────────────────
              ContentCard(
                onTap: _reloading ? null : _reload,
                child: Row(
                  children: [
                    if (_reloading)
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    else
                      Icon(Icons.sync_outlined, size: 22, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('重新加载规则',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text('热切换 rules/ 目录（运行中生效，无需重启拦截）',
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // ── 匹配自检入口 ────────────────────────────────────────────
              ContentCard(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MatchTestPage(controller: widget.controller))),
                child: Row(
                  children: [
                    Icon(Icons.fact_check_outlined,
                        size: 22, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('匹配自检',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text('输入域名即时查询判定（无网络副作用）',
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 22, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // ── 外部规则目录 ────────────────────────────────────────────
              ContentCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder_outlined,
                            size: 20, color: cs.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Text('外部规则目录',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.controller.rulesDir.isEmpty
                          ? 'files/rules/'
                          : widget.controller.rulesDir,
                      style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: cs.primary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '订阅下载的 txt 与用户规则都落在这里，内核 *.txt 全量加载'
                      '（M4-R1：内核无内嵌规则，规则全部外部可见；'
                      '首启自动写入 starter.txt 与 protected-allow.txt 种子）。',
                      style: TextStyle(
                          fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

// ── 订阅源卡 ─────────────────────────────────────────────────────────────────

class _SourcesCard extends StatelessWidget {
  const _SourcesCard({
    required this.updatingAll,
    required this.progress,
    required this.onUpdateAll,
    required this.onAdd,
    required this.onSourceMenu,
    required this.onUpdateOne,
  });

  final bool updatingAll;
  final String progress;
  final VoidCallback onUpdateAll;
  final VoidCallback onAdd;
  final void Function(BuildContext anchor, SourceConfig s) onSourceMenu;
  final Future<void> Function(SourceConfig s) onUpdateOne;

  String _statusLine(SourceConfig s, SourceMeta? meta, String? lastError) {
    if (lastError != null) return '上次错误：$lastError';
    if (meta == null || meta.fetchedAt.isEmpty) return '从未更新';
    final t = DateTime.tryParse(meta.fetchedAt)?.toLocal();
    final when = t == null
        ? ''
        : '· ${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ';
    return '${meta.lines} 行 $when'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final svc = SubscriptionService.instance;
    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.rss_feed_outlined, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('订阅源',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              GlassSurface(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                onTap: updatingAll ? null : onUpdateAll,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_download_outlined,
                        size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Text('全部更新',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: cs.primary)),
                  ],
                ),
              ),
            ],
          ),
          if (updatingAll && progress.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(progress,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (svc.sources.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无订阅源',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ),
          for (final s in svc.sources)
            _SourceRow(
              source: s,
              meta: svc.metas[s.id],
              lastError: svc.lastErrors[s.id],
              statusLine: _statusLine(s, svc.metas[s.id], svc.lastErrors[s.id]),
              busy: updatingAll,
              onMenu: (anchor) => onSourceMenu(anchor, s),
              onUpdateTap: () => unawaited(onUpdateOne(s)),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassSurface(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              onTap: updatingAll ? null : onAdd,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16, color: cs.onSurface),
                  const SizedBox(width: 4),
                  Text('添加订阅源',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.meta,
    required this.lastError,
    required this.statusLine,
    required this.busy,
    required this.onMenu,
    required this.onUpdateTap,
  });

  final SourceConfig source;
  final SourceMeta? meta;
  final String? lastError;
  final String statusLine;
  final bool busy;
  final ValueChanged<BuildContext> onMenu;
  final VoidCallback onUpdateTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = source.enabled;
    final fg = enabled ? cs.onSurface : cs.onSurfaceVariant.withValues(alpha: 0.5);
    final statusColor = lastError != null
        ? cs.error
        : (meta == null || meta!.fetchedAt.isEmpty ? cs.onSurfaceVariant : cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Opacity(
              opacity: enabled ? 1 : 0.45,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: fg)),
                      ),
                      if (!enabled) ...[
                        const SizedBox(width: 6),
                        Text('已停用',
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(urlHost(source.url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(statusLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 行尾菜单（anchor 跟随图标自身）
          Builder(
            builder: (anchor) => GlassSurface(
              circle: true,
              height: 36,
              onTap: busy ? null : () => onMenu(anchor),
              child: Icon(Icons.more_vert, size: 18, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 添加订阅源弹窗 ───────────────────────────────────────────────────────────

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  bool _urlOk(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  void _submit(BuildContext dialogContext) {
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = '名称与 URL 均不能为空');
      return;
    }
    if (!_urlOk(url)) {
      setState(() => _error = 'URL 需以 http:// 或 https:// 开头');
      return;
    }
    // 同步捕获 messenger，避免跨 async gap 持有 BuildContext
    final messenger = ScaffoldMessenger.maybeOf(dialogContext);
    unawaited(() async {
      await SubscriptionService.instance.addSource(name, url);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('已添加 $name'),
            width: 320,
            behavior: SnackBarBehavior.floating));
    }());
    Navigator.of(dialogContext, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GlassAlertDialog(
      title: '添加订阅源',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              hintText: '名称（如 my-list）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'https://…（AdGuard 语法 txt）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(fontSize: 12.5, color: cs.error)),
          ],
        ],
      ),
      actions: [
        GlassDialogAction('取消',
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop()),
        GlassDialogAction('添加',
            emphasized: true, onPressed: () => _submit(context)),
      ],
    );
  }
}

// ── 用户规则底部弹层 ─────────────────────────────────────────────────────────

class _UserRulesSheet extends StatefulWidget {
  const _UserRulesSheet({required this.controller});

  final AppController controller;

  @override
  State<_UserRulesSheet> createState() => _UserRulesSheetState();
}

class _UserRulesSheetState extends State<_UserRulesSheet> {
  final _input = TextEditingController();
  List<String> _lines = [];
  bool _allow = false; // false=拦截（默认），true=放行
  bool _busy = false;

  SubscriptionService get _svc => SubscriptionService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final lines = await _svc.readUserRuleLines();
    if (!mounted) return;
    setState(() => _lines = lines);
  }

  void _snack(String msg) {
    final ctx = Navigator.of(context, rootNavigator: true).context;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg),
          width: 360,
          behavior: SnackBarBehavior.floating));
  }

  Future<void> _apply(String okMsg) async {
    setState(() => _busy = true);
    final rc = await widget.controller.applyUserRules(List.of(_lines));
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(rc == 0 ? '$okMsg（热切换 rc=0）' : '已写文件但热切换失败（rc=$rc）');
    await _load();
  }

  Future<void> _add() async {
    if (_busy) return;
    final domain = _input.text.trim().toLowerCase();
    if (domain.isEmpty) return;
    if (!isValidDomain(domain)) {
      _snack('域名不合法：仅 [a-z0-9.-]，≤253，且至少一个点');
      return;
    }
    final line = formatUserRuleLine(domain, allow: _allow);
    if (_lines.contains(line)) {
      _snack('规则已存在：$line');
      return;
    }
    _lines.add(line);
    _input.clear();
    await _apply('已添加 $line');
  }

  Future<void> _deleteAt(int i) async {
    if (_busy) return;
    final removed = _lines.removeAt(i);
    await _apply('已删除 $removed');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = parseUserRules(_lines.join('\n'));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: entries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: EmptyState(
                      icon: Icons.edit_note_outlined,
                      title: '还没有用户规则',
                      subtitle: '在下方输入域名，选择拦截或放行后添加',
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final isBlock = e.kind == UserRuleKind.block;
                      final color = e.kind == UserRuleKind.other
                          ? cs.onSurfaceVariant
                          : (isBlock ? cs.error : cs.primary);
                      return Row(
                        children: [
                          Icon(
                            e.kind == UserRuleKind.other
                                ? Icons.help_outline
                                : (isBlock
                                    ? Icons.block_outlined
                                    : Icons.verified_outlined),
                            size: 18,
                            color: color,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              e.kind == UserRuleKind.other
                                  ? e.raw
                                  : e.domain,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontFamily: 'monospace',
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                          if (e.kind != UserRuleKind.other)
                            Text(isBlock ? '拦截' : '放行',
                                style: TextStyle(fontSize: 11.5, color: color)),
                          IconButton(
                            icon: Icon(Icons.close,
                                size: 18, color: cs.onSurfaceVariant),
                            tooltip: '删除',
                            onPressed: _busy ? null : () => unawaited(_deleteAt(i)),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 10),
          // 底部输入行：域名 + 拦截/放行 分段 + 添加
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_add()),
                  style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                  strutStyle:
                      const StrutStyle(forceStrutHeight: true, height: 1.25),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '域名，如 ads.example.com',
                    hintStyle: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8)),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _Segmented(
                allow: _allow,
                onChange: (v) => setState(() => _allow = v),
              ),
              const SizedBox(width: 8),
              GlassSurface(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                onTap: _busy ? null : () => unawaited(_add()),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('添加',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: cs.primary)),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// 拦截/放行 两档分段选择（Material 档简版，滚动区外无玻璃压力）。
class _Segmented extends StatelessWidget {
  const _Segmented({required this.allow, required this.onChange});

  final bool allow;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget seg(String label, bool value, Color active) {
      final selected = allow == value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChange(value),
        child: AnimatedContainer(
          duration: GlassTokens.motionDuration,
          curve: GlassTokens.motionCurve,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? active.withValues(alpha: 0.16)
                : cs.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color:
                    selected ? active.withValues(alpha: 0.5) : Colors.transparent),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? active : cs.onSurfaceVariant)),
        ),
      );
    }

    return Row(children: [
      seg('拦截', false, cs.error),
      const SizedBox(width: 4),
      seg('放行', true, cs.primary),
    ]);
  }
}
