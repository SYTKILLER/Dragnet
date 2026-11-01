import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

import 'glass_scope.dart';
import 'glass_tokens.dart';

/// 统一按下反馈（指南 §4.4）：按下缩放 0.96 + 底色加深，120ms easeOut。
class GlassPressable extends StatefulWidget {
  const GlassPressable({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.scale = GlassTokens.pressedScale,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final double scale;

  @override
  State<GlassPressable> createState() => _GlassPressableState();
}

class _GlassPressableState extends State<GlassPressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final child = AnimatedScale(
      scale: _pressed ? widget.scale : 1.0,
      duration: GlassTokens.pressDuration,
      curve: GlassTokens.pressCurve,
      child: widget.builder(context, _pressed),
    );
    if (!widget.enabled || (widget.onTap == null && widget.onLongPress == null)) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: child,
    );
  }
}

/// 全站唯一材质收口（指南 §4.2）：四档尺寸语义完全一致（height 紧约束、
/// width null 抱内容、circle 取正方），换档不动布局。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.height = GlassTokens.pillHeight,
    this.width,
    this.padding = EdgeInsets.zero,
    this.circle = false,
    this.borderRadius,
    this.elevated = true,
    this.materialize = 1.0,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry padding;
  final bool circle;
  final BorderRadius? borderRadius;
  final bool elevated;

  /// 材质在场程度 0→1（显隐走这里，⛔ 玻璃外禁 Opacity）。
  final double materialize;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final backend = panelOrChromeBackend(context);
    final content = Padding(padding: padding, child: child);
    final dimmed = _dimContent(context, content, materialize);

    Widget box = switch (backend) {
      GlassBackend.easyLens => _EasyLensBox(
          height: height,
          width: circle ? height : width,
          circle: circle,
          borderRadius: borderRadius,
          elevated: elevated,
          materialize: materialize,
          child: dimmed,
        ),
      GlassBackend.liquidWidgets => _WidgetsGlassBox(
          height: height,
          width: circle ? height : width,
          circle: circle,
          borderRadius: borderRadius,
          elevated: elevated,
          materialize: materialize,
          child: dimmed,
        ),
      GlassBackend.plain => _PlainBox(
          height: height,
          width: circle ? height : width,
          circle: circle,
          borderRadius: borderRadius,
          materialize: materialize,
          child: dimmed,
        ),
      GlassBackend.material => _MaterialBox(
          height: height,
          width: circle ? height : width,
          circle: circle,
          borderRadius: borderRadius,
          materialize: materialize,
          child: dimmed,
        ),
    };

    return GlassPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      enabled: enabled && (onTap != null || onLongPress != null),
      builder: (_, pressed) {
        if (!pressed) return box;
        // 按下底色加深：液态/材质档换 pressed tint。
        final cs = Theme.of(context).colorScheme;
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(
              end: backend == GlassBackend.material
                  ? GlassTokens.materialPressedFill(cs)
                  : null),
          duration: GlassTokens.pressDuration,
          curve: GlassTokens.pressCurve,
          child: box,
          builder: (context, color, child) => color == null
              ? child!
              : _TintOverride(tint: color, child: child!),
        );
      },
    );
  }

  /// materialize 压内容走【颜色通道】不是 Opacity（不建图层，折射不断）。
  Widget _dimContent(BuildContext context, Widget content, double m) {
    if (m >= 1) return content;
    var result =
        IconTheme.merge(data: IconThemeData(opacity: m), child: content);
    final textColor = DefaultTextStyle.of(context).style.color;
    if (textColor != null) {
      result = DefaultTextStyle.merge(
        style: TextStyle(color: textColor.withValues(alpha: m)),
        child: result,
      );
    }
    return result;
  }
}

/// 供档选择：浮出面板锚定上下文钉 easy（panelGlassBackend 的应用点在
/// showGlassMenu 里就地重建 scope），这里只区分 chrome 与 flat。
GlassBackend panelOrChromeBackend(BuildContext context) {
  final scope = context
      .dependOnInheritedWidgetOfExactType<_GlassBackendOverride>();
  if (scope != null) return scope.backend;
  return chromeGlassBackend(context);
}

/// 就地改写子树供档（showGlassMenu 把 easy 档挂到根 Overlay 时用）。
class GlassBackendOverride extends StatelessWidget {
  const GlassBackendOverride({
    super.key,
    required this.backend,
    required this.child,
  });

  final GlassBackend backend;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _GlassBackendOverride(backend: backend, child: child);
}

class _GlassBackendOverride extends InheritedWidget {
  const _GlassBackendOverride({required this.backend, required super.child});

  final GlassBackend backend;

  @override
  bool updateShouldNotify(_GlassBackendOverride oldWidget) =>
      oldWidget.backend != backend;
}

class _TintOverride extends InheritedWidget {
  const _TintOverride({required this.tint, required super.child});

  final Color tint;

  @override
  bool updateShouldNotify(_TintOverride oldWidget) => oldWidget.tint != tint;
}

Color? _pressedTintOf(BuildContext context) {
  final o = context.dependOnInheritedWidgetOfExactType<_TintOverride>();
  return o?.tint;
}

// ── easy 档：真折射透镜（指南 §4.3 LiquidGlassBox）──────────────────────
class _EasyLensBox extends StatelessWidget {
  const _EasyLensBox({
    required this.child,
    required this.height,
    required this.width,
    required this.circle,
    required this.borderRadius,
    required this.elevated,
    required this.materialize,
  });

  final Widget child;
  final double? height;
  final double? width;
  final bool circle;
  final BorderRadius? borderRadius;
  final bool elevated;
  final double materialize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = circle
        ? (height ?? GlassTokens.pillHeight) / 2
        : (borderRadius?.resolve(Directionality.of(context)).topLeft.x ??
            (height ?? GlassTokens.pillHeight) / 2);
    // 正圆用 roundedRectangle（最省）；胶囊用 continuousRoundedRectangle
    final cornerStyle = circle
        ? LiquidGlassCornerStyle.roundedRectangle
        : LiquidGlassCornerStyle.continuousRoundedRectangle;
    final r = GlassTokens.liquidRefraction;
    final pressed = _pressedTintOf(context);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
          end: pressed ??
              GlassTokens.liquidTint(cs).withValues(
                  alpha:
                      GlassTokens.liquidTint(cs).a * materialize)),
      duration: GlassTokens.pressDuration,
      curve: GlassTokens.pressCurve,
      child: child,
      builder: (context, tint, child) {
        return SizedBox(
          height: height,
          width: circle ? height : width,
          child: LiquidGlassLens(
            style: LiquidGlassStyle(
              shape: LiquidGlassShape(
                cornerStyle: cornerStyle,
                cornerRadius: radius,
                borderWidth: GlassTokens.liquidBorderWidth,
                borderType: OpticalBorder(
                  borderSaturation:
                      GlassTokens.liquidOpticalBorder.borderSaturation,
                  ambientIntensity:
                      GlassTokens.liquidOpticalBorder.ambientIntensity,
                ),
              ),
              appearance: LiquidGlassAppearance(
                color: tint ?? GlassTokens.liquidTint(cs),
                blur: LiquidGlassBlur(
                    sigmaX: GlassTokens.liquidBlur.sigmaX,
                    sigmaY: GlassTokens.liquidBlur.sigmaY),
                saturation: GlassTokens.liquidSaturation,
                shadow: elevated
                    ? LiquidGlassShadow(
                        blur: 7,
                        opacity: cs.brightness == Brightness.dark ? 0.28 : 0.16,
                        offset: const Offset(0, 2),
                      )
                    : null,
              ),
              refraction: LiquidGlassRefraction(
                distortion: r.distortion,
                distortionWidth: r.distortionWidth,
                chromaticAberration: r.ca,
              ),
            ),
            // 尺寸钉死才开跟手形变，否则 lens 拿 constraints.biggest 会撑爆
            touch: _pinned
                ? const LiquidGlassTouch(flex: LiquidGlassFlex.subtle())
                : null,
            child: child!,
          ),
        );
      },
    );
  }

  bool get _pinned => height != null && (circle || width != null);
}

// ── widgets 档：页面 chrome（指南 §4.3 LiquidWidgetsGlassBox，v1 单块态）──
class _WidgetsGlassBox extends StatelessWidget {
  const _WidgetsGlassBox({
    required this.child,
    required this.height,
    required this.width,
    required this.circle,
    required this.borderRadius,
    required this.elevated,
    required this.materialize,
  });

  final Widget child;
  final double? height;
  final double? width;
  final bool circle;
  final BorderRadius? borderRadius;
  final bool elevated;
  final double materialize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = circle
        ? (height ?? GlassTokens.pillHeight) / 2
        : (borderRadius?.resolve(Directionality.of(context)).topLeft.x ??
            (height ?? GlassTokens.pillHeight) / 2);
    final shape = circle
        ? const lgw.LiquidOval()
        : lgw.LiquidRoundedSuperellipse(borderRadius: radius);
    final pressed = _pressedTintOf(context);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
          end: pressed ??
              GlassTokens.widgetsTint(cs).withValues(
                  alpha: GlassTokens.widgetsTint(cs).a * materialize)),
      duration: GlassTokens.pressDuration,
      curve: GlassTokens.pressCurve,
      child: child,
      builder: (context, tint, child) {
        final glass = SizedBox(
          height: height,
          width: circle ? height : width,
          child: lgw.AdaptiveGlass(
            shape: shape,
            quality: chromeGlassQuality,
            settings: lgw.LiquidGlassSettings(
              glassColor: tint ?? GlassTokens.widgetsTint(cs),
              visibility: materialize,
              shadow: const [],
              blur: 5,
            ),
            allowElevation: elevated,
            // 影子画在形变层外（GlassOuterShadow），玻璃层自己关
            clipExpansion: GlassTokens.glassClipExpansion,
            child: child!,
          ),
        );
        return _GlassOuterShadow(
          shadows: elevated && cs.brightness == Brightness.light
              ? GlassTokens.widgetsShadow(alphaScale: materialize)
              : const [],
          radius: radius,
          bodySize: Size(width ?? double.infinity, height ?? 0),
          circle: circle,
          child: glass,
        );
      },
    );
  }
}

/// 挖洞画影（指南 §4.3）：离屏画影 + 内部 clear，防止半透明玻璃压在暗斑上变浑。
class _GlassOuterShadow extends StatelessWidget {
  const _GlassOuterShadow({
    required this.shadows,
    required this.radius,
    required this.bodySize,
    required this.circle,
    required this.child,
  });

  final List<BoxShadow> shadows;
  final double radius;
  final Size bodySize;
  final bool circle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (shadows.isEmpty || !bodySize.isFinite) return child;
    final reach = shadows.fold<double>(
        0, (m, s) => m + s.blurRadius + s.spreadRadius + s.offset.distance);
    return CustomPaint(
      foregroundPainter: _OuterShadowPainter(
        shadows: shadows,
        radius: radius,
        bodySize: bodySize,
        circle: circle,
      ),
      size: Size.infinite,
      isComplex: true,
      child: Padding(padding: EdgeInsets.all(reach + 4), child: child),
    );
  }
}

class _OuterShadowPainter extends CustomPainter {
  _OuterShadowPainter({
    required this.shadows,
    required this.radius,
    required this.bodySize,
    required this.circle,
  });

  final List<BoxShadow> shadows;
  final double radius;
  final Size bodySize;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Rect.fromLTWH(0, 0, bodySize.width, bodySize.height);
    final rrect = RRect.fromRectAndRadius(
        body, Radius.circular(circle ? bodySize.width / 2 : radius));
    canvas.saveLayer(body.inflate(60), ui.Paint());
    for (final shadow in shadows) {
      canvas.drawRRect(
        rrect.shift(shadow.offset).inflate(shadow.spreadRadius),
        ui.Paint()
          ..color = shadow.color
          ..maskFilter =
              const ui.MaskFilter.blur(ui.BlurStyle.normal, 6),
      );
    }
    canvas.drawRRect(rrect, ui.Paint()..blendMode = ui.BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter oldDelegate) =>
      oldDelegate.shadows != shadows ||
      oldDelegate.radius != radius ||
      oldDelegate.bodySize != bodySize;
}

// ── plain 档：贴在内容上的半透明膜（无 blur 无投影）──────────────────────
class _PlainBox extends StatelessWidget {
  const _PlainBox({
    required this.child,
    required this.height,
    required this.width,
    required this.circle,
    required this.borderRadius,
    required this.materialize,
  });

  final Widget child;
  final double? height;
  final double? width;
  final bool circle;
  final BorderRadius? borderRadius;
  final double materialize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = circle
        ? (height ?? GlassTokens.pillHeight) / 2
        : (borderRadius?.resolve(Directionality.of(context)).topLeft.x ??
            (height ?? GlassTokens.pillHeight) / 2);
    Color dim(Color c) => c.withValues(alpha: c.a * materialize);
    final pressed = _pressedTintOf(context);
    final base = pressed ?? GlassTokens.fill(cs);

    return AnimatedContainer(
      duration: GlassTokens.pressDuration,
      curve: GlassTokens.pressCurve,
      height: height,
      width: circle ? height : width,
      decoration: BoxDecoration(
        color: dim(base),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
        border: Border.all(color: dim(GlassTokens.stroke(cs)), width: 0.6),
        // ⛔ 无投影：这档是"贴在内容上的膜"，投影会把它读成浮起的卡片
      ),
      child: child,
    );
  }
}

// ── material 档：自洽 M3（不透明，无描边/投影/形变）─────────────────────
class _MaterialBox extends StatelessWidget {
  const _MaterialBox({
    required this.child,
    required this.height,
    required this.width,
    required this.circle,
    required this.borderRadius,
    required this.materialize,
  });

  final Widget child;
  final double? height;
  final double? width;
  final bool circle;
  final BorderRadius? borderRadius;
  final double materialize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = circle
        ? (height ?? GlassTokens.pillHeight) / 2
        : (borderRadius?.resolve(Directionality.of(context)).topLeft.x ??
            (height ?? GlassTokens.pillHeight) / 2);
    final pressed = _pressedTintOf(context);
    final base = pressed ?? GlassTokens.materialFill(cs);

    return AnimatedContainer(
      duration: GlassTokens.pressDuration,
      curve: GlassTokens.pressCurve,
      height: height,
      width: circle ? height : width,
      decoration: BoxDecoration(
        color: materialize >= 1 ? base : base.withValues(alpha: base.a * materialize),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}
