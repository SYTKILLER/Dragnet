import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';
import 'match_test_page.dart';

/// 规则页（对齐鸿蒙 RulesPage）：规则规模（ruleInfo）+ 匹配自检入口 +
/// 外部规则指引。
class RulesPage extends StatelessWidget {
  const RulesPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    return GlassHeaderOverlay(
      title: '规则',
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final info = controller.ruleInfo;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
            children: [
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
              // 匹配自检入口
              ContentCard(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MatchTestPage(controller: controller))),
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
                      controller.rulesDir.isEmpty
                          ? 'files/rules/'
                          : controller.rulesDir,
                      style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: cs.primary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '把订阅 txt 放进应用 filesDir/rules/ 后重启拦截即生效'
                      '（M4-R1：内核无内嵌规则，规则全部外部可见）。\n'
                      'adb push rules/starter.txt /data/local/tmp/ 后用 '
                      'run-as 拷入（详见 android/README）。',
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
