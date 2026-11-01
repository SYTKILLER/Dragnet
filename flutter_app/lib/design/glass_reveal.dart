import 'dart:async';

import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'glass_tokens.dart';

/// 滚动旁听器（指南 §5.4）：挂在根 NotificationListener 上，滚动期间
/// [scrolling] 为 true——回顶浮钮此时整只不建（液态档每块独立玻璃每帧
/// 一次 backdrop 采样，恰好在光栅最紧时少一层）。
class ScrollActivityMonitor {
  ScrollActivityMonitor._();
  static final ScrollActivityMonitor instance = ScrollActivityMonitor._();

  static const settleDelay = Duration(milliseconds: 300);
  Timer? _settle;

  final ValueNotifier<bool> scrolling = ValueNotifier<bool>(false);

  bool handle(ScrollNotification n) {
    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
      _settle?.cancel();
      scrolling.value = true;
    } else if (n is ScrollEndNotification) {
      _settle?.cancel();
      _settle = Timer(settleDelay, () => scrolling.value = false);
    }
    return false; // 只旁听
  }
}

/// 第十原语"浮现"（指南 §12）：AnimatedSlide + materialize tween，全程无
/// Opacity 压玻璃；退场跑完不建 child（materialize=0 的壳 = 看得见的裸图标
/// + 点不着的 IgnorePointer）。
class GlassReveal extends StatelessWidget {
  const GlassReveal({
    super.key,
    required this.visible,
    required this.builder,
    this.slideFrom = const Offset(0, 0.4),
  });

  final bool visible;
  final Widget Function(BuildContext context, double materialize) builder;
  final Offset slideFrom;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: visible ? 1 : 0),
      duration: GlassTokens.motionDuration,
      curve: GlassTokens.motionCurve,
      onEnd: () {},
      builder: (context, m, child) {
        final shown = m > 0.001;
        // 退场跑完整只不建 child
        if (!shown && !visible) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedSlide(
            offset: Offset(slideFrom.dx * (1 - m), slideFrom.dy * (1 - m)),
            duration: Duration.zero,
            child: builder(context, m.clamp(0.0, 1.0).toDouble()),
          ),
        );
      },
    );
  }
}

/// 回顶浮钮（指南 §5.4）：pixels ≥ 300 且滚动静止时浮现。
class ScrollToTopFab extends StatelessWidget {
  const ScrollToTopFab({super.key, required this.visible, this.onPressed});

  final bool visible;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ScrollActivityMonitor.instance.scrolling,
      builder: (_, scrolling, _) {
        return GlassReveal(
          visible: visible && !scrolling,
          builder: (_, m) => GlassSurface(
            materialize: m,
            circle: true,
            onTap: onPressed,
            child: Icon(Icons.vertical_align_top,
                size: GlassTokens.iconSize, color: Theme.of(context).colorScheme.onSurface),
          ),
        );
      },
    );
  }
}
