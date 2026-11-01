import 'package:flutter/material.dart';

import 'edge_fade_scrim.dart';
import 'glass_scope.dart';
import 'glass_surface.dart';
import 'glass_tokens.dart';

/// 通用页面骨架（指南 §7.1，v1 收口：整行 chrome 收进一只玻璃胶囊——
/// 一块玻璃 = 一次 backdrop 采样，与"融合层收一层"同等收益且零 API 风险；
/// 多块融合留 v2 用 AdaptiveLiquidGlassLayer）。
///
/// 内容从 header 背后滚过；调用方自己 paddingTop = [headerExtentOf]。
class GlassHeaderOverlay extends StatelessWidget {
  const GlassHeaderOverlay({
    super.key,
    required this.title,
    required this.body,
    this.leading,
    this.actions = const <Widget>[],
    this.onTitleTap,
    this.busy = false,
    this.extra = const <Widget>[],
  });

  final String title;
  final Widget body;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;
  final bool busy;
  final List<Widget> extra;

  static double headerExtentOf(BuildContext context) =>
      MediaQuery.of(context).padding.top + GlassTokens.headerRowHeight;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 列表压回便宜档（⛔ lens 不进滚动容器）
        Positioned.fill(
          child: GlassBackendOverride(
            backend: flatGlassBackend(context),
            child: body,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: EdgeFadeScrim.headerOverlay(
            statusBar: statusBar,
            headerRowHeight: GlassTokens.headerRowHeight,
          ),
        ),
        Positioned(
          top: statusBar,
          left: GlassTokens.chromeGap + 8,
          right: GlassTokens.chromeGap + 8,
          height: GlassTokens.headerRowHeight,
          child: GlassSurface(
            height: GlassTokens.headerRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                ?leading,
                Expanded(
                  child: _HeaderTitle(
                    title: title,
                    busy: busy,
                    onTap: onTitleTap,
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
        ...extra,
      ],
    );
  }
}

/// header 内的图标位：玻璃胶囊内的内容段，按压反馈走缩放+底色，
/// 不再各自套壳。
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.title, required this.busy, this.onTap});

  final String title;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: text),
            if (busy) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// header 图标按钮（胶囊内内容段）。
class HeaderIconButton extends StatefulWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? tooltip;
  final Color? color;

  @override
  State<HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<HeaderIconButton> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = Icon(
      widget.icon,
      size: GlassTokens.iconSize,
      color: widget.color ?? cs.onSurface,
    );
    Widget result = GlassPressable(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      builder: (_, pressed) => AnimatedContainer(
        duration: GlassTokens.pressDuration,
        curve: GlassTokens.pressCurve,
        width: GlassTokens.pillHeight - 6,
        height: GlassTokens.headerRowHeight - 12,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: pressed
              ? cs.onSurface.withValues(alpha: 0.08)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: icon,
      ),
    );
    if (widget.tooltip != null) {
      result = Tooltip(
        message: widget.tooltip!,
        triggerMode: TooltipTriggerMode.manual,
        child: result,
      );
    }
    return result;
  }
}
