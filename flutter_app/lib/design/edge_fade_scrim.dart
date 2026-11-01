import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass_tokens.dart';

/// 渐进蒙层（指南 §7.2）：代替实色栏，靠边缘保持 peakAlpha，越靠内容越透明，
/// 列表"溶"进边缘。⛔ 不用 BackdropFilter（省一整屏采样）。
class EdgeFadeScrim extends StatelessWidget {
  const EdgeFadeScrim._({
    required this.height,
    required this.gradient,
  });

  final double height;
  final LinearGradient gradient;

  /// 页面顶部 header 蒙层：平台段（状态栏）恒 [peakAlpha]，header 行本身
  /// 是淡出的一部分，尾巴再滑 [tailExtent]。
  factory EdgeFadeScrim.headerOverlay({
    required double statusBar,
    required double headerRowHeight,
    double peakAlpha = 0.72,
  }) {
    final fadeExtent = headerRowHeight + GlassTokens.headerFadeExtent;
    final (stops, alphas) = _buildCurve(
      height: fadeExtent,
      solidExtent: statusBar,
      peakAlpha: peakAlpha,
    );
    return EdgeFadeScrim._(
      height: fadeExtent,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: stops,
        colors: [
          for (final a in alphas) Color.fromARGB((a * 255).round(), 0, 0, 0)
        ],
      ),
    );
  }

  /// 底部蒙层：平台段（导航条区）恒 [peakAlpha]，之上是栏高 + 尾巴。
  factory EdgeFadeScrim.bottom({
    required double safeBottom,
    required double reservedExtent,
    double peakAlpha = 0.72,
  }) {
    final solidExtent = safeBottom;
    final fadeExtent = safeBottom +
        reservedExtent +
        GlassTokens.bottomFadeExtent;
    final (stops, alphas) = _buildCurve(
      height: fadeExtent,
      solidExtent: solidExtent,
      peakAlpha: peakAlpha,
      reverse: true,
    );
    return EdgeFadeScrim._(
      height: fadeExtent,
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        stops: stops,
        colors: [
          for (final a in alphas) Color.fromARGB((a * 255).round(), 0, 0, 0)
        ],
      ),
    );
  }

  /// 曲线：[0, plateau] 恒 peakAlpha → smoothstep(u)=u²(3-2u) 衰减到 0，
  /// 16 段 stops（线性分段在拐点有台阶）。
  static (List<double>, List<double>) _buildCurve({
    required double height,
    required double solidExtent,
    double peakAlpha = 0.72,
    bool reverse = false,
  }) {
    final plateau = (solidExtent / height).clamp(0.0, 0.95);
    const n = 16;
    final stops = <double>[];
    final alphas = <double>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      final u = t <= plateau ? 0.0 : (t - plateau) / (1 - plateau);
      final a = t <= plateau
          ? peakAlpha
          : peakAlpha * (1 - _smoothstep(u));
      stops.add(t);
      alphas.add(a);
    }
    return (stops, alphas);
  }

  static double _smoothstep(double u) {
    final c = u.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 蒙层基色 = surface；alpha 由渐变自带
    final colors = [
      for (final c in gradient.colors) cs.surface.withValues(alpha: c.a / 255)
    ];
    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: gradient.begin,
            end: gradient.end,
            stops: gradient.stops,
            colors: colors,
          ),
        ),
      ),
    );
  }
}

double clamp01(double v) => math.min(1.0, math.max(0.0, v));
