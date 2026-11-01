import 'package:flutter/material.dart';

/// 液态玻璃设计系统唯一参数源（复现指南 §3）。
/// 所有组件从这里取值——换材质不换尺寸/动效。
abstract final class GlassTokens {
  // ── 尺寸 ────────────────────────────────────────────────────────────────
  static const double pillHeight = 44; // 玻璃胶囊/圆钮标准高度
  static const double iconSize = 22; // 标准图标
  static const double strokeWidth = 0.6; // 传统档描边宽
  static const double headerRowHeight = 56; // header 行高（不含状态栏）
  static const double headerFadeExtent = 24; // header 下方蒙层尾巴
  static const double scrimFadeTailRatio = 24 / 56; // 蒙层尾巴÷可淡出高度
  static const double floatingTabBarHeight = 64; // 浮动底栏高
  static const double floatingTabBarBottomMargin = 4; // 距底部安全区
  static const double floatingTabBarSideMargin = 16; // 左右边距
  /// 底栏旁圆钮直径——必须恒等于栏高，小了会被包拉成椭圆
  static const double floatingActionSize = floatingTabBarHeight;
  /// 列表为底栏额外让出的高度 = 64+4+8
  static const double floatingBarReservedExtent =
      floatingTabBarHeight + floatingTabBarBottomMargin + 8;
  static const double bottomFadeExtent = 24; // 底部蒙层在底栏之上的延伸
  /// 同行玻璃间距 = 融合阈值（同一个数，必须一起改）
  static const double chromeGap = 8;
  static const double identityBadgeSize = 9; // 未读红点直径
  static const double dialogWideBreakpoint = 600; // 宽窄分界
  /// 单块玻璃 RepaintBoundary 裁剪外扩（盖住影子 + 按压余量）
  static const EdgeInsets glassClipExpansion = EdgeInsets.all(16);

  // ── 动效 ────────────────────────────────────────────────────────────────
  static const Duration pressDuration = Duration(milliseconds: 120);
  static const Curve pressCurve = Curves.easeOut;
  static const Duration motionDuration = Duration(milliseconds: 200);
  static const Curve motionCurve = Curves.easeOutCubic;
  static const double pressedScale = 0.96;
  static const Duration bottomBarDuration = Duration(milliseconds: 320);
  static const Duration groupMorphDuration = Duration(milliseconds: 340);
  static const Curve groupSlotCurve = Curves.easeInOutCubic;
  static const Duration dialogEnterDuration = Duration(milliseconds: 260);
  static const Duration dialogExitDuration = Duration(milliseconds: 190);
  static const Curve dialogEnterCurve = Curves.easeOutCubic;
  static const Curve dialogExitCurve = Curves.easeInCubic;
  /// 弹窗淡入（70% 处实体化，尾巴留给形变）
  static final Curve dialogFadeInCurve =
      const Interval(0, 0.7, curve: Curves.easeOut);
  /// 弹窗淡出（80% 处已全透明，不撑到最后一帧）
  static final Curve dialogFadeOutCurve = const Interval(0.2, 1);

  // ── 颜色（随 ColorScheme，亮暗自适应）─────────────────────────────────
  /// 传统档（plain）："贴在内容上的一层半透明膜"，无 blur 无投影。
  /// 0.80 会让底下内容顶穿面板，恒 0.94。
  static Color fill(ColorScheme cs) =>
      cs.surfaceContainerLow.withValues(alpha: 0.94);
  static Color pressedFill(ColorScheme cs) => Color.alphaBlend(
      cs.onSurface.withValues(alpha: 0.08), fill(cs));
  static Color stroke(ColorScheme cs) => cs.outlineVariant.withValues(
      alpha: cs.brightness == Brightness.dark ? 0.55 : 0.45);
  static Color selectedHighlight(ColorScheme cs) =>
      cs.secondaryContainer.withValues(alpha: 0.9);

  /// Material 档：浮起的东西必须比页面底色高一档；无透明/描边/投影/形变。
  static Color materialFill(ColorScheme cs) => cs.surfaceContainerHigh;
  static Color materialPressedFill(ColorScheme cs) => Color.alphaBlend(
      cs.onSurface.withValues(alpha: 0.10), materialFill(cs));

  /// 液态 chrome（widgets 档）色调：chrome 只托几枚图标，透明度给真玻璃量级；
  /// 深色用黑——白纱在全暗背景上不生效。
  static Color widgetsTint(ColorScheme cs) => cs.brightness == Brightness.dark
      ? Colors.black.withValues(alpha: 0.24)
      : Colors.white.withValues(alpha: 0.10);
  static Color widgetsPressedTint(ColorScheme cs) => Color.alphaBlend(
      cs.onSurface.withValues(alpha: 0.08), widgetsTint(cs));

  /// 液态浮出面板（easy 档）色调——比 chrome 厚，面板要托住整页文字。
  static Color liquidTint(ColorScheme cs) => cs.brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.white.withValues(alpha: 0.45);

  // ── 液态参数（easy 档，指南 §3.4 调参红线见注释）─────────────────────
  /// 身后高频化开，折射才不糊成噪点
  static const LiquidGlassBlurX liquidBlur = LiquidGlassBlurX(14, 14);
  static const double liquidSaturation = 1.0; // 提饱和会让灰背景偏色发浑
  /// 液态描边是 shader 画的光带，0.6 太细看不出"厚度"
  static const double liquidBorderWidth = 1.2;
  /// 小胶囊上 distortion > 0.18 会把边缘文字拽变形；distortionWidth 不能
  /// 超过胶囊半高 22
  static const ({double distortion, double distortionWidth, double ca})
      liquidRefraction = (distortion: 0.12, distortionWidth: 18, ca: 0.004);
  /// ambient 只垫光，borderSolidity 恒 0（同时拉大会变成纯色描边，液态感全无）
  static const ({double borderSaturation, double ambientIntensity})
      liquidOpticalBorder = (borderSaturation: 1.4, ambientIntensity: 1.2);

  static Color liquidShadowColor(ColorScheme cs, {double alphaScale = 1}) =>
      Colors.black.withValues(
          alpha: (cs.brightness == Brightness.dark ? 0.28 : 0.16) * alphaScale);

  // ── 液态参数（widgets 档）────────────────────────────────────────────
  /// iOS 26 口径投影：一层弥散 + 一层贴地。⛔ 只在浅色画（深色包自己跳过）
  static List<BoxShadow> widgetsShadow({double alphaScale = 1}) => [
        BoxShadow(
            color: Colors.black.withValues(alpha: 0.07 * alphaScale),
            blurRadius: 6,
            offset: const Offset(0, 2)),
        BoxShadow(
            color: Colors.black.withValues(alpha: 0.03 * alphaScale),
            blurRadius: 2,
            offset: const Offset(0, 1)),
      ];
}

/// blur 的中性载体（避免设计层直接依赖 easy 包类型）。
class LiquidGlassBlurX {
  final double sigmaX;
  final double sigmaY;
  const LiquidGlassBlurX(this.sigmaX, this.sigmaY);
}
