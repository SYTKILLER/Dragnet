import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 首页仪表盘（对齐鸿蒙 DashboardPage 口径）：状态主卡 + 拦截开关 +
/// DNS 查询占比 + TCP/UDP 概览。
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    return GlassHeaderOverlay(
      title: '罗网 Dragnet',
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
            children: [
              _StatusCard(controller: controller),
              const SizedBox(height: 16),
              _PowerSwitch(controller: controller),
              const SizedBox(height: 16),
              _DnsShareCard(controller: controller),
              const SizedBox(height: 16),
              _ProtocolGrid(controller: controller),
              if (controller.startError != null) ...[
                const SizedBox(height: 16),
                ContentCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 20, color: cs.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          controller.startError!,
                          style: TextStyle(fontSize: 13, color: cs.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = controller.running;
    final starting = controller.starting;
    final accent = running ? cs.primary : cs.onSurfaceVariant;
    return ContentCard(
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: starting
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: accent),
                  )
                : Icon(
                    running ? Icons.verified_user_outlined : Icons.shield_outlined,
                    size: 28,
                    color: accent,
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  starting
                      ? '内核启动中…'
                      : running
                          ? '拦截运行中'
                          : '拦截已停止',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  running
                      ? '已运行 ${formatUptime(controller.stats!.uptimeSec)}'
                      : '域名级广告 / 跟踪器拦截',
                  style: TextStyle(
                      fontSize: 13,
                      color: running ? cs.primary : cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (running ? cs.primary : cs.outlineVariant)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              running ? '运行中' : '未运行',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: running ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PowerSwitch extends StatelessWidget {
  const _PowerSwitch({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = controller.running;
    final busy = controller.starting;
    return Center(
      child: GlassSurface(
        circle: true,
        height: 72,
        onTap: busy
            ? null
            : () {
                if (running) {
                  controller.stopBlock();
                } else {
                  controller.startBlock();
                }
              },
        child: Icon(
          Icons.power_settings_new,
          size: 32,
          color: running ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _DnsShareCard extends StatelessWidget {
  const _DnsShareCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = controller.stats;
    final blocked = s?.dnsBlocked ?? 0;
    final forwarded = s?.dnsForwarded ?? 0;
    final total = blocked + forwarded;
    final ratio = total == 0 ? 0.0 : blocked / total;
    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DNS 查询占比',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ShareItem(
                    label: '阻断', value: '$blocked', color: cs.error),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _ShareItem(
                    label: '放行', value: '$forwarded', color: cs.primary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  Expanded(
                    flex: total == 0 ? 1 : blocked,
                    child: ColoredBox(color: cs.error),
                  ),
                  Expanded(
                    flex: total == 0 ? 1 : forwarded,
                    child: ColoredBox(
                        color: cs.primary.withValues(alpha: 0.45)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            total == 0 ? '暂无 DNS 查询' : '阻断率 ${(ratio * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ShareItem extends StatelessWidget {
  const _ShareItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _ProtocolGrid extends StatelessWidget {
  const _ProtocolGrid({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = controller.stats;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2.6,
      children: [
        StatTile(label: 'TCP 阻断', value: '${s?.tcpBlocked ?? 0}'),
        StatTile(label: 'TCP 转发', value: '${s?.tcpRelayed ?? 0}'),
        StatTile(label: 'UDP 阻断', value: '${s?.udpBlocked ?? 0}'),
        StatTile(label: 'UDP 转发', value: '${s?.udpRelayed ?? 0}'),
        StatTile(
            label: 'DNS 阻断', value: '${s?.dnsBlocked ?? 0}', valueColor: cs.error),
        StatTile(
            label: '真实 IP 缓存',
            value: '${s?.cache ?? 0}',
            valueColor: cs.primary),
      ],
    );
  }
}
