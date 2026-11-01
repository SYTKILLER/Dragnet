import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 匹配自检子页（对齐鸿蒙 MatchTestPage）：输入域名即时查询当前引擎。
class MatchTestPage extends StatefulWidget {
  const MatchTestPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<MatchTestPage> createState() => _MatchTestPageState();
}

class _MatchTestPageState extends State<MatchTestPage> {
  final _fieldController = TextEditingController();
  MatchResult? _result;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _fieldController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final domain = _fieldController.text.trim().toLowerCase();
    if (domain.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await widget.controller.matchTest(domain);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res == null) {
        _error = '引擎空载或查询失败（先启动拦截并加载规则）';
      } else {
        _result = res;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    final cs = Theme.of(context).colorScheme;
    return GlassHeaderOverlay(
      title: '匹配自检',
      leading: HeaderIconButton(
        icon: Icons.arrow_back,
        tooltip: '返回',
        onTap: () => Navigator.of(context).maybePop(),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
        children: [
          // 玻璃输入域（指南 §11.5 口径：fill 膜 + 无边框 TextField，Align 居中）
          GlassSurface(
            height: 48,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Icon(Icons.language,
                        size: 20, color: cs.onSurfaceVariant),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextField(
                        controller: _fieldController,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _run(),
                        style: const TextStyle(fontSize: 15),
                        strutStyle: const StrutStyle(
                            forceStrutHeight: true, height: 1.25),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '例如 doubleclick.net',
                          hintStyle: TextStyle(
                              fontSize: 15,
                              color: cs.onSurfaceVariant.withValues(alpha: 0.8)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GlassSurface(
                    circle: true,
                    height: 40,
                    onTap: _busy ? null : _run,
                    child: _busy
                        ? const Padding(
                            padding: EdgeInsets.all(11),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.search,
                            size: 20, color: cs.onSurface),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            ContentCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 20, color: cs.error),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(_error!,
                          style: TextStyle(fontSize: 13, color: cs.error))),
                ],
              ),
            )
          else if (_result != null)
            _ResultCard(result: _result!)
          else
            const ContentCard(
              padding: EdgeInsets.all(20),
              child: Column(
                children: [
                  SizedBox(height: 12),
                  EmptyState(
                    icon: Icons.manage_search,
                    title: '输入域名开始检测',
                    subtitle: 'BLOCK=命中阻断规则 · ALLOW=命中白名单 · NOMATCH=无规则命中',
                  ),
                  SizedBox(height: 12),
                ],
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final MatchResult result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isBlock = result.action == 'BLOCK';
    final isAllow = result.action == 'ALLOW';
    final color = isBlock
        ? cs.error
        : isAllow
            ? Colors.green.shade600
            : cs.onSurfaceVariant;
    final label = switch (result.action) {
      'BLOCK' => '阻断',
      'ALLOW' => '放行（白名单）',
      _ => '无规则命中',
    };
    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  result.action,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: color),
                ),
              ),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 14, color: color)),
            ],
          ),
          const SizedBox(height: 14),
          _DetailRow(label: '命中规则', value: result.rule.isEmpty ? '—' : result.rule),
          const SizedBox(height: 6),
          _DetailRow(label: '来源列表', value: result.list.isEmpty ? '—' : result.list),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
