import 'package:flutter/material.dart';

import '../design/glass_header.dart';
import '../design/glass_scope.dart';
import '../design/glass_surface.dart';
import '../design/glass_tokens.dart';
import '../state/app_controller.dart';
import 'common_cards.dart';

/// 首页仪表盘：Hero 主卡（状态 + 一键启停合并，运行态主色实心钮 + 微光
/// 外环）+ 顶部环境光 + DNS 查询占比 + TCP/UDP 概览 + 启动失败原因
/// （lastError）透出。转发日志已升一级 Tab、匹配自检仅保留规则页入口
/// （2026-11-22 UI 评审口径），首页不再放操作入口卡。
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
          return Stack(
            fit: StackFit.expand,
            children: [
              // ⓪ 底层环境光：给玻璃搭折射舞台（画在列表背后，不建图层）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 320,
                child: _AmbientGlow(running: controller.running),
              ),
              ListView(
                padding: EdgeInsets.fromLTRB(
                    16, statusBar + GlassTokens.headerRowHeight + 12, 16, 16),
                children: [
                  _HeroCard(controller: controller),
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
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶部环境光：液态玻璃的底色若纯平发灰，折射就没了舞台——运行中透出
/// 主色（深青）微光，已停止收束为冷灰。RadialGradient 顶心扩散，仅在
/// 首屏上半区，随运行状态 500ms 过渡。
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = running ? cs.primary : cs.onSurfaceVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1.15),
          radius: 1.5,
          colors: [
            accent.withValues(alpha: running ? 0.14 : 0.06),
            accent.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// Hero 主卡：状态与启停合一。左侧 72px 电源钮（运行=主色实心 + 柔和外环
/// 微光；停止=玻璃/材质底 + 描边），右侧状态标题 + 运行时长 + 规则规模。
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = controller.running;
    final starting = controller.starting;
    final info = controller.ruleInfo;
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
              _PowerButton(controller: controller),
              const SizedBox(width: 16),
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
                    const SizedBox(height: 4),
                    Text(
                      running
                          ? '已运行 ${formatUptime(controller.stats?.uptimeSec ?? 0)}'
                          : '域名级广告 / 跟踪器拦截',
                      style: TextStyle(
                        fontSize: 13,
                        color: running ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                    if (info != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${info.lists} 个规则列表 · ${info.ruleLines} 行',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
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

/// 电源钮：一键开启全机防护的 Hero 锚点。运行态主色实心圆 + 外环微光；
/// 停止态回退各自档位的卡底（液态=膜、材质=surfaceContainerHigh）。
class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = controller.running;
    final busy = controller.starting;
    final idleFill = GlassMaterialScope.isLiquid(context)
        ? GlassTokens.fill(cs)
        : GlassTokens.materialFill(cs);
    return GlassPressable(
      onTap: busy
          ? null
          : () {
              if (running) {
                controller.stopBlock();
              } else {
                controller.startBlock();
              }
            },
      builder: (_, pressed) => AnimatedContainer(
        duration: GlassTokens.pressDuration,
        curve: GlassTokens.pressCurve,
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: running
              ? cs.primary
              : (pressed ? GlassTokens.pressedFill(cs) : idleFill),
          boxShadow: running
              ? [
                  // 柔和外环微光：Hero 的"开机"仪式感（非玻璃件，允许投影）
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.32),
                    blurRadius: 22,
                    spreadRadius: 2,
                    offset: const Offset(0, 3),
                  ),
                ]
              : const [],
          border: running
              ? null
              : Border.all(color: GlassTokens.stroke(cs), width: 0.6),
        ),
        child: busy
            ? Padding(
                padding: const EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  color: running ? cs.onPrimary : cs.primary,
                ),
              )
            : Icon(
                Icons.power_settings_new,
                size: 34,
                color: running ? cs.onPrimary : cs.onSurfaceVariant,
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
              // ⛔ 无查询时不画 1:1 红/青（会被读成"50% 被拦截"），渲染纯灰底轨
              child: total == 0
                  ? ColoredBox(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.12))
                  : Row(
                      children: [
                        Expanded(
                          child: ColoredBox(color: cs.error),
                        ),
                        Expanded(
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
        // tabularFigures：轮询刷新时数字宽度稳定，不左右微抖
        Text(value,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()])),
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
