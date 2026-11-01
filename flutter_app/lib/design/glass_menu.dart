import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass_scope.dart';
import 'glass_surface.dart';
import 'glass_tokens.dart';

/// 弹出玻璃菜单项（指南 §9.4）。
class GlassMenuOption {
  const GlassMenuOption({
    required this.label,
    this.icon,
    this.description,
    this.selected = false,
    this.destructive = false,
    this.accentColor,
    this.trailing,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final String? description;
  final bool selected;
  final bool destructive;
  final Color? accentColor;
  final String? trailing;
  final VoidCallback? onTap;
}

/// 全站替代 PopupMenuButton 的下拉面板（指南 §9）。材质钉死 easyLens；
/// 出入场"卷开"（Telegram 式），全程无 Opacity 压玻璃——玻璃的显隐走
/// materialize（压材质自身 alpha，不建图层，backdrop 采样不断）。
Future<T?> showGlassMenu<T extends Object?>(
  BuildContext context, {
  required List<GlassMenuOption> options,
  Rect? anchor,
  double? width,
}) async {
  final box = context.findRenderObject() as RenderBox?;
  anchor ??= box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : const Rect.fromLTWH(24, 80, 44, 44);

  final navigator = Navigator.of(context, rootNavigator: true);
  final backend = panelGlassBackend(context);

  return navigator.push<T>(_GlassMenuRoute<T>(
    anchor: anchor,
    options: options,
    width: width,
    backend: backend,
  ));
}

class _GlassMenuRoute<T> extends PopupRoute<T> {
  _GlassMenuRoute({
    required this.anchor,
    required this.options,
    required this.backend,
    double? width,
  }) : panelWidth = width ?? _measureWidth(options);

  final Rect anchor;
  final List<GlassMenuOption> options;
  final GlassBackend backend;
  final double panelWidth;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  Duration get _enterDuration =>
      Duration(milliseconds: (160 + 16 * options.length).clamp(200, 300));

  @override
  Duration get transitionDuration => _enterDuration;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return LayoutBuilder(builder: (context, constraints) {
      final rowsHeight = options.fold<double>(0, (sum, o) {
        return sum + (o.description != null ? 60 : 44) + 1;
      });
      final estimatedHeight = (rowsHeight + 12).clamp(60.0, 560.0).toDouble();
      final below = anchor.bottom + 8 + estimatedHeight <= constraints.maxHeight;
      final top = below
          ? anchor.bottom + 8
          : math.max(8.0, anchor.top - 8 - estimatedHeight);
      final left =
          (anchor.left).clamp(8.0, math.max(8.0, constraints.maxWidth - panelWidth - 8)).toDouble();

      return Stack(
        fit: StackFit.expand,
        children: [
          // 吞掉遮罩命中：ModalBarrier 在路由层已处理，这里只为布局
          Positioned(
            left: left,
            top: top,
            width: panelWidth,
            child: _GlassMenuPanel(
              options: options,
              backend: backend,
              origin: below ? Alignment.topLeft : Alignment.bottomLeft,
              animation: animation,
            ),
          ),
        ],
      );
    });
  }

  /// 面板宽：TextPainter 静态量出精确尺寸（开菜单前钉死）。
  static double _measureWidth(List<GlassMenuOption> options) {
    var widest = 0.0;
    for (final o in options) {
      final tp = TextPainter(
        text: TextSpan(
          text: o.label,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      widest = widest > tp.width ? widest : tp.width;
      tp.dispose();
    }
    // 图标槽 22 + 间距 10 + 文本 + trailing 槽 60 + 行内边距 24，clamp(176, 320)
    return (widest + 22 + 10 + 60 + 24).clamp(176.0, 320.0).toDouble() + 6;
  }
}

class _GlassMenuPanel extends StatelessWidget {
  const _GlassMenuPanel({
    required this.options,
    required this.backend,
    required this.origin,
    required this.animation,
  });

  final List<GlassMenuOption> options;
  final GlassBackend backend;
  final AlignmentGeometry origin;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 卷开（指南 §9.1）：外层从触发件大小撑到成品，内层反向抵消——内容
    // 全程自然尺寸待在原地，未卷到的部分由玻璃自身形状裁掉。
    final panel = GlassBackendOverride(
      backend: backend,
      child: GlassSurface(
        height: null,
        width: null,
        materialize: _materialize.value,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < options.length; i++) ...[
              _GlassMenuEntryReveal(
                progress: animation,
                startShare: options.length <= 1 ? 0 : (i / (options.length * 2)),
                child: _GlassMenuRow(option: options[i], colorScheme: cs),
              ),
              if (i < options.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Container(
                    height: 1,
                    color: cs.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ],
        ),
      ),
    );

    // 起手缩放 = anchor.size / panel.size（量不出时 fallback (0.90, 0.32)）
    final entry = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 1, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: entry,
      builder: (context, child) {
        final t = entry.value.clamp(0.0, 1.0);
        final sx = (0.90 + (1 - 0.90) * t);
        final sy = (0.32 + (1 - 0.32) * t);
        return Transform(
          alignment: origin,
          transform: _scale(sx, sy),
          child: Transform(
            alignment: origin,
            transform: _scale(1 / sx, 1 / sy),
            child: child,
          ),
        );
      },
      child: panel,
    );
  }

  Animation<double> get _materialize => CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.38, curve: Curves.easeOut),
        reverseCurve: const Interval(0, 0.5, curve: Curves.easeIn),
      );

  static Matrix4 _scale(double sx, double sy) =>
      Matrix4.diagonal3Values(sx, sy, 1);
}

/// 条目错峰（在玻璃【内部】，透明度层建在 backdrop 采样之后，合法）。
class _GlassMenuEntryReveal extends StatelessWidget {
  const _GlassMenuEntryReveal({
    required this.progress,
    required this.startShare,
    required this.child,
  });

  final Animation<double> progress;
  final double startShare;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: progress,
      curve: Interval(startShare, (startShare + 0.5).clamp(0.0, 1.0),
          curve: Curves.easeOut),
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        final t = curved.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - t)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _GlassMenuRow extends StatelessWidget {
  const _GlassMenuRow({required this.option, required this.colorScheme});

  final GlassMenuOption option;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final o = option;
    final fg = o.destructive
        ? cs.error
        : o.accentColor ?? cs.onSurface;

    final row = GlassPressable(
      onTap: o.onTap == null
          ? null
          : () => Navigator.of(context, rootNavigator: true).pop(),
      builder: (_, pressed) {
        final bg = pressed
            ? cs.onSurface.withValues(alpha: 0.10)
            : Colors.transparent;
        return AnimatedContainer(
          duration: GlassTokens.pressDuration,
          curve: GlassTokens.pressCurve,
          height: o.description != null ? 60 : 44,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              if (o.icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(o.icon, size: 20, color: fg),
                )
              else
                const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      o.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          color: fg),
                    ),
                    if (o.description != null)
                      Text(
                        o.description!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (o.trailing != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 88),
                    child: Text(
                      o.trailing!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              if (o.selected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, size: 18, color: cs.primary),
                ),
            ],
          ),
        );
      },
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: row,
    );
  }
}
