import 'package:flutter/material.dart';

import '../design/glass_surface.dart';

/// plain 档大卡片（页面内容卡统一走便宜档：滚动容器内禁 lens）。
/// 圆角固定 20px：GlassSurface 默认回退 pillHeight/2=22 用在内容卡上接近
/// 胶囊；且"大卡套小卡"时 22 套 22 破坏同心圆角秩序（2026-11-22 UI 评审）。
class ContentCard extends StatelessWidget {
  const ContentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      height: null,
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      padding: padding,
      child: child,
    );
  }
}

/// 统计小卡：数值 + 标签。嵌在另一张大卡内部时传 flat=true——退化为
/// 无描边低对比色块（同心圆角 12px），避免玻璃卡套玻璃卡。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.flat = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      // 定高容器（仪表盘 GridView aspect 钳高）下垂直居中，避免顶部堆积溢出
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: valueColor ?? cs.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
    if (flat) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: content,
      );
    }
    return ContentCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: content,
    );
  }
}

/// 空态（统计/规则页"未运行"口径，对齐鸿蒙端）。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
