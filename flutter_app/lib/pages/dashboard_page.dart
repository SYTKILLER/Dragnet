import 'dart:async';

import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';
import 'logs_page.dart';
import 'match_test_page.dart';

/// 首页仪表盘（对齐鸿蒙 DashboardPage 口径）：状态主卡 + 拦截开关 +
/// 操作入口（转发日志/匹配自检）+ DNS 查询占比 + TCP/UDP 概览 +
/// 启动失败原因（lastError）透出。
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
              // 操作区：转发日志 + 匹配自检（并排，风格同规则页入口卡）
              // ⛔ 滚动区无界高度，禁 stretch（等高靠两侧内容结构一致自然对齐）
              Row(
                children: [
                  Expanded(
                    child: _EntryCard(
                      controller: controller,
                      icon: Icons.receipt_long_outlined,
                      title: '转发日志',
                      caption: 'DNS/TCP/UDP 判定',
                      onTap: () => unawaited(Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  LogsPage(controller: controller)))),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _EntryCard(
                      controller: controller,
                      icon: Icons.fact_check_outlined,
                      title: '匹配自检',
                      caption: '输入域名查判定',
                      onTap: () => unawaited(Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  MatchTestPage(controller: controller)))),
                    ),
                  ),
                ],
              ),
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
    // 启动失败原因透出（方向1 功能4）：未运行且 lastStartRc≠0 → 显示 lastError
    final showKernelError = !running &&
        !starting &&
        controller.lastStartRc != 0 &&
        controller.kernelLastError != null &&
        controller.kernelLastError!.isNotEmpty;
    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                        running
                            ? Icons.verified_user_outlined
                            : Icons.shield_outlined,
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
          if (showKernelError) ...[
            const SizedBox(height: 10),
            Text(
              '启动失败 rc=${controller.lastStartRc}：${controller.kernelLastError}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: cs.error,
                  fontFamily: 'monospace',
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ],
      ),
    );
  }
}

/// 操作区入口卡（风格同规则页入口卡，半宽两列并排）。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.controller,
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final AppController controller;
  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ContentCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface)),
                Text(caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
              ],
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
      // M6-B：2.6 → 154.5/2.6=59.4px 定高装不下 StatTile 内容（20px 数值行+
      // 12px 标签行+24 padding≈71px），测试环境 6 格全溢出 14px（走查 🟡 3.5px
      // 同源）。2.1 → 73.6px 收口，内容居中。
      childAspectRatio: 2.1,
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
