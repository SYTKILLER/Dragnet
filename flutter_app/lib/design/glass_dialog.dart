import 'package:flutter/material.dart';

import 'glass_scope.dart';
import 'glass_surface.dart';
import 'glass_tokens.dart';

/// 全站弹窗唯一入口（指南 §11.1）：双通道过渡——形变 260/190ms + 淡入淡出
/// 曲线错峰。这里是全站唯一允许 FadeTransition 的地方：弹窗面板本身是不
/// 透明 Material(cs.surface)，身后没有页面可折射，Opacity 伤害不存在。
Future<T?> showAppDialog<T extends Object?>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    _GlassDialogRoute<T>(builder: builder, barrierDismissible: barrierDismissible),
  );
}

class _GlassDialogRoute<T> extends PopupRoute<T> {
  _GlassDialogRoute({required this.builder, required this.barrierDismissible});

  final WidgetBuilder builder;
  @override
  final bool barrierDismissible;

  @override
  Color get barrierColor => Colors.black54;

  @override
  String? get barrierLabel => '关闭弹窗';

  @override
  Duration get transitionDuration => GlassTokens.dialogEnterDuration;

  @override
  Duration get reverseTransitionDuration => GlassTokens.dialogExitDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return builder(context);
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return _GlassDialogTransition(animation: animation, child: child);
  }
}

class _GlassDialogTransition extends StatelessWidget {
  const _GlassDialogTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 淡入早收工（内容 70% 处已实体化，尾巴留给形变）、淡出早退场
    final fade = CurvedAnimation(
      parent: animation,
      curve: GlassTokens.dialogFadeInCurve,
      reverseCurve: GlassTokens.dialogFadeOutCurve,
    );
    final scale = CurvedAnimation(
      parent: animation,
      curve: GlassTokens.dialogEnterCurve,
      reverseCurve: GlassTokens.dialogExitCurve,
    );
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: Tween(begin: 0.92, end: 1.0).animate(scale),
        child: child,
      ),
    );
  }
}

/// 标准确认弹窗（指南 §11.2）。⛔ 关弹窗必须 rootNavigator pop（路由挂根）。
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    required this.title,
    this.content,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Material(
          color: cs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          clipBehavior: Clip.antiAlias,
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    GlassSurface(
                      circle: true,
                      onTap: () =>
                          Navigator.of(context, rootNavigator: true).pop(),
                      child: Icon(Icons.close,
                          size: 20, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (content != null)
                  Flexible(
                    child: GlassBackendOverride(
                      backend: flatGlassBackend(context),
                      child: content!,
                    ),
                  ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final a in actions)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: a,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 文字动作位（取消/确认组）。字号 14.5、w600（主动作 w700+主色）、
/// 危险动作 cs.error、按下 scale 0.94、不自绘暗底。
class GlassDialogAction extends StatelessWidget {
  const GlassDialogAction(
    this.label, {
    super.key,
    this.onPressed,
    this.destructive = false,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = destructive
        ? cs.error
        : emphasized
            ? cs.primary
            : cs.onSurface;
    return GlassPressable(
      onTap: onPressed,
      scale: 0.94,
      builder: (_, pressed) => AnimatedDefaultTextStyle(
        duration: GlassTokens.pressDuration,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
          color: color.withValues(alpha: onPressed == null ? 0.38 : 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(label),
        ),
      ),
    );
  }
}

/// 底部弹层（指南 §11.3）：壳本身不透明（弹层壳不变玻璃；玻璃只给壳内按钮）。
/// ⛔ 底部安全区在 Material【内部】Padding 让位。
Future<T?> showGlassBottomSheet<T extends Object?>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  bool scrollable = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return RepaintBoundary(
        child: GlassBackendOverride(
          backend: flatGlassBackend(sheetContext),
          child: Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
            child: Material(
              color: cs.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 拖拽把手
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              style: Theme.of(sheetContext).textTheme.titleLarge),
                        ),
                        GlassSurface(
                          circle: true,
                          onTap: () =>
                              Navigator.of(sheetContext, rootNavigator: true).pop(),
                          child: Icon(Icons.close,
                              size: 20, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.of(sheetContext).padding.bottom,
                          left: 20,
                          right: 20),
                      child: scrollable
                          ? SingleChildScrollView(child: builder(sheetContext))
                          : builder(sheetContext),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
