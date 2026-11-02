import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/glass_header.dart';
import '../design/glass_menu.dart';
import '../design/glass_reveal.dart';
import '../design/glass_tokens.dart';
import '../services/rule_source.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 转发日志页（方向1 功能2）：进入 logs(0) 全量拉一次，之后 1.5s 增量轮询
/// （返回 cursor）；本页通过 Navigator.push 打开，出栈 dispose 即停轮询。
/// 点行可把域名写入用户规则（zzz-user-rules.txt）并热切换。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _localCap = 2000; // 本地保留上限，超出丢最旧

  final List<LogEvent> _events = []; // 升序追加
  final ScrollController _scroll = ScrollController();
  int _cursor = 0;
  bool _pulling = false;
  bool _showFab = false;
  String _filter = 'all'; // all | block | allow | forward
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(_poll)); // 进入即全量拉一次
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      unawaited(_poll());
    });
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.position.pixels >= 300;
    if (show != _showFab) setState(() => _showFab = show);
  }

  Future<void> _poll() async {
    if (_pulling || !mounted) return;
    _pulling = true;
    final chunk = await widget.controller.fetchLogs(_cursor);
    _pulling = false;
    if (!mounted || chunk == null || chunk.events.isEmpty) return;
    setState(() {
      _events.addAll(chunk.events);
      if (_events.length > _localCap) {
        _events.removeRange(0, _events.length - _localCap);
      }
      if (chunk.cursor > _cursor) _cursor = chunk.cursor;
    });
  }

  List<LogEvent> get _filtered {
    final Iterable<LogEvent> it = switch (_filter) {
      'block' => _events.where((e) => e.action == 'block'),
      'allow' => _events.where((e) => e.action == 'allow'),
      'forward' =>
        _events.where((e) => e.action == 'forward' || e.action == 'relay'),
      _ => _events,
    };
    return it.toList().reversed.toList(); // 最新在上
  }

  void _clearScreen() {
    // 只清本地视图并把 cursor 钉在已拉到的最新 id；内核环不动。
    setState(_events.clear);
  }

  void _snack(String msg) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg),
          width: 340,
          behavior: SnackBarBehavior.floating));
  }

  Future<void> _rowMenu(LogEvent e) async {
    final domain = e.domain;
    await showGlassMenu(
      context,
      options: [
        GlassMenuOption(
          label: '加入拦截',
          icon: Icons.block_outlined,
          description: domain.isEmpty ? '该条无域名' : formatUserRuleLine(domain, allow: false),
          onTap: domain.isEmpty ? null : () => _addUserRule(domain, false),
        ),
        GlassMenuOption(
          label: '加入放行',
          icon: Icons.verified_outlined,
          description: domain.isEmpty ? '该条无域名' : formatUserRuleLine(domain, allow: true),
          onTap: domain.isEmpty ? null : () => _addUserRule(domain, true),
        ),
        GlassMenuOption(
          label: '复制域名',
          icon: Icons.copy_outlined,
          description: domain.isEmpty ? e.dest : domain,
          onTap: () {
            Clipboard.setData(ClipboardData(text: domain.isEmpty ? e.dest : domain));
            _snack('已复制');
          },
        ),
      ],
    );
  }

  Future<void> _addUserRule(String domain, bool allow) async {
    final svc = SubscriptionService.instance;
    if (svc.rulesDir.isEmpty) {
      _snack('规则目录未就绪');
      return;
    }
    final lines = await svc.readUserRuleLines();
    final line = formatUserRuleLine(domain, allow: allow);
    if (lines.contains(line)) {
      _snack('规则已存在：$line');
      return;
    }
    lines.add(line);
    final rc = await widget.controller.applyUserRules(lines);
    if (!mounted) return;
    _snack(rc == 0
        ? '已加入${allow ? '放行' : '拦截'}并热切换（rc=0）'
        : '写入成功但热切换失败（rc=$rc）');
  }

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    final viewBottom = MediaQuery.of(context).padding.bottom;
    final filtered = _filtered;
    return GlassHeaderOverlay(
      title: '转发日志',
      leading: HeaderIconButton(
        icon: Icons.arrow_back,
        tooltip: '返回',
        onTap: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        HeaderIconButton(
          icon: Icons.delete_sweep_outlined,
          tooltip: '清屏（不动内核记录）',
          onTap: filtered.isEmpty ? null : _clearScreen,
        ),
      ],
      body: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(
            16, statusBar + GlassTokens.headerRowHeight + 12, 16, 24 + viewBottom),
        itemCount: filtered.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return _Header(
              filter: _filter,
              count: filtered.length,
              onFilter: (v) => setState(() => _filter = v),
            );
          }
          final e = filtered[i - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _LogRow(event: e, onTap: () => unawaited(_rowMenu(e))),
          );
        },
      ),
      extra: [
        Positioned(
          right: 16,
          bottom: 24 + viewBottom,
          child: ScrollToTopFab(
            visible: _showFab,
            onPressed: () => unawaited(_scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 320),
                curve: GlassTokens.motionCurve)),
          ),
        ),
      ],
    );
  }
}

/// 顶部过滤 chips + 计数（在滚动区内，不建 lens 材质）。
class _Header extends StatelessWidget {
  const _Header({
    required this.filter,
    required this.count,
    required this.onFilter,
  });

  final String filter;
  final int count;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget chip(String label, String value) {
      final selected = filter == value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onFilter(value),
        child: AnimatedContainer(
          duration: GlassTokens.motionDuration,
          curve: GlassTokens.motionCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? cs.primary.withValues(alpha: 0.16)
                : cs.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected
                    ? cs.primary.withValues(alpha: 0.5)
                    : Colors.transparent),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip('全部', 'all'),
                  const SizedBox(width: 8),
                  chip('拦截', 'block'),
                  const SizedBox(width: 8),
                  chip('放行', 'allow'),
                  const SizedBox(width: 8),
                  chip('转发', 'forward'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('$count 条',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}

/// 单条日志：action 着色圆点 + 域名（加粗）+ 等宽副行。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.event, required this.onTap});

  final LogEvent event;
  final VoidCallback onTap;

  Color actionColor(ColorScheme cs) => switch (event.action) {
        'block' => cs.error,
        'allow' => cs.primary,
        _ => cs.onSurfaceVariant,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = actionColor(cs);
    final title = event.domain.isEmpty ? event.dest : event.domain;
    final time = DateTime.fromMillisecondsSinceEpoch(event.ts);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final ruleOrList = event.rule.isNotEmpty
        ? event.rule
        : (event.list.isNotEmpty ? event.list : '—');
    final subParts = [
      '$hh:$mm:$ss',
      event.kind,
      ruleOrList,
      if (event.dest.isNotEmpty && event.domain.isNotEmpty) event.dest,
    ];
    return ContentCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: title.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            switch (event.action) {
              'block' => '拦截',
              'allow' => '放行',
              'forward' => '转发',
              'relay' => '中继',
              _ => event.action,
            },
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
