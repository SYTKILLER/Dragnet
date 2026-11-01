import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 统计页（对齐鸿蒙 StatsPage）：运行时 8 项计数；未运行空态。
class StatsPage extends StatelessWidget {
  const StatsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    return GlassHeaderOverlay(
      title: '统计',
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final s = controller.stats;
          if (!controller.running || s == null) {
            return ListView(
              padding: EdgeInsets.fromLTRB(
                  16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
              children: const [
                SizedBox(height: 120),
                EmptyState(
                  icon: Icons.query_stats_outlined,
                  title: '内核未运行',
                  subtitle: '在首页启动拦截后，这里展示运行统计',
                ),
              ],
            );
          }
          final cs = Theme.of(context).colorScheme;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
            children: [
              ContentCard(
                child: Row(
                  children: [
                    Icon(Icons.timer_outlined,
                        size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('已运行 ${formatUptime(s.uptimeSec)}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.6,
                children: [
                  StatTile(
                      label: 'DNS 阻断',
                      value: '${s.dnsBlocked}',
                      valueColor: cs.error),
                  StatTile(
                      label: 'DNS 放行',
                      value: '${s.dnsForwarded}',
                      valueColor: cs.primary),
                  StatTile(label: 'TCP 阻断', value: '${s.tcpBlocked}'),
                  StatTile(label: 'TCP 转发', value: '${s.tcpRelayed}'),
                  StatTile(label: 'UDP 阻断', value: '${s.udpBlocked}'),
                  StatTile(label: 'UDP 转发', value: '${s.udpRelayed}'),
                  StatTile(
                      label: '真实 IP 缓存条目',
                      value: '${s.cache}',
                      valueColor: cs.primary),
                ],
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
