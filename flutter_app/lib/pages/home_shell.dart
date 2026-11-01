import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

import '../design/edge_fade_scrim.dart';
import '../design/glass_scope.dart';
import '../design/glass_tokens.dart';

/// 悬浮导航栏壳（指南 §6）。⛔ 不放 Scaffold.bottomNavigationBar——Scaffold
/// 检测到该槽非 null 就给 body 套 removeBottom，全站 SafeArea 失效。一律
/// Stack 覆盖层 + 把底栏占用高度【加进】padding.bottom。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.tabs,
    required this.pages,
    required this.extraOnTap,
    required this.extraLabel,
    required this.extraIcon,
    this.currentIndex = 0,
  });

  final List<String> tabs;
  final List<Widget> pages;
  final VoidCallback extraOnTap;
  final String extraLabel;
  final IconData extraIcon;
  final int currentIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.currentIndex;

  // ── 落地时机状态机（指南 §6.3）：按住只留给拖动，抬手才换页 ──────────
  bool _pointerDown = false;
  bool _movedBeyondSlop = false;
  Offset _downPosition = Offset.zero;
  int? _pressedIndex; // 视觉立刻跟手
  int? _pending;
  bool _pendingFromPress = false;
  bool _commitScheduled = false;

  int get _visualIndex => _pressedIndex ?? _index;

  void _handlePointerDown(PointerDownEvent e) {
    _pointerDown = true;
    _movedBeyondSlop = false;
    _downPosition = e.position;
  }

  void _handlePointerMove(PointerMoveEvent e) {
    if (!_movedBeyondSlop &&
        (e.position - _downPosition).distance > kTouchSlop) {
      _movedBeyondSlop = true;
    }
  }

  void _handlePointerRelease(PointerEvent e) {
    _pointerDown = false;
    _scheduleCommit();
  }

  void _handleTabSelected(int index) {
    _pending = index;
    _pendingFromPress = _pointerDown;
    _setPressedIndex(index); // 视觉立刻跟过去
    if (_pointerDown) return; // 换页压着等抬手
    _scheduleCommit();
  }

  void _scheduleCommit() {
    if (_commitScheduled) return;
    _commitScheduled = true;
    scheduleMicrotask(_commit);
  }

  void _commit() {
    _commitScheduled = false;
    if (!mounted || _pointerDown) return;
    final index = _pending;
    final fromPress = _pendingFromPress;
    _pending = null;
    if (index == null) return;
    if (fromPress && _movedBeyondSlop) {
      _setPressedIndex(null); // 拖走了：抢跑作废
      return;
    }
    setState(() => _index = index);
  }

  void _setPressedIndex(int? index) {
    if (_pressedIndex == index) return;
    setState(() => _pressedIndex = index);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _pressedIndex = null; // 交还路由
    }
  }

  // ── 标签上限公式（指南 §6.2）：每格 ConstrainedBox 单行省略，图标恒定 ──
  double _labelMaxWidth({
    required double barWidth,
    required int tabCount,
    required bool hasAction,
  }) {
    if (!barWidth.isFinite || tabCount <= 0) return double.infinity;
    final capsule = barWidth - (hasAction ? GlassTokens.floatingTabBarHeight + 12 : 0);
    final slot = capsule / tabCount;
    return slot <= 24 ? 24 : slot - 8;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final safeBottom = mq.padding.bottom;
    const reserved = GlassTokens.floatingBarReservedExtent;
    final isLiquid = GlassMaterialScope.isLiquid(context);

    final content = IndexedStack(index: _visualIndex, children: widget.pages);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ⓪ 把底栏高度【加进】padding.bottom：页面让位逻辑自动生效
          MediaQuery(
            data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: safeBottom + reserved)),
            child: content,
          ),
          // ① 底部渐进蒙层（不含底栏本体）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: EdgeFadeScrim.bottom(
              safeBottom: safeBottom,
              reservedExtent: reserved,
            ),
          ),
          // ④ 底栏本体（外边距由 Stack 负责，bar 内 padding 全 0）
          Positioned(
            left: GlassTokens.floatingTabBarSideMargin,
            right: GlassTokens.floatingTabBarSideMargin,
            bottom: safeBottom + GlassTokens.floatingTabBarBottomMargin,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerRelease,
              onPointerCancel: _handlePointerRelease,
              child: isLiquid
                  ? _buildLiquidBar(context)
                  : _buildMaterialBar(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabContent(BuildContext context, int i, bool selected) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = _labelMaxWidth(
        barWidth: constraints.hasBoundedWidth && constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 360,
        tabCount: widget.tabs.length,
        hasAction: true,
      );
      return MediaQuery(
        // 栏高钉死，系统字号拉满会顶破槽位（指南 §6.2）
        data: MediaQuery.of(context).copyWith(
            textScaler:
                MediaQuery.of(context).textScaler.clamp(maxScaleFactor: 1.2)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _tabIcon(i),
                size: 26,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 2),
              Text(
                widget.tabs[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  IconData _tabIcon(int i) => switch (i) {
        0 => Icons.security_outlined,
        1 => Icons.query_stats_outlined,
        2 => Icons.rule_outlined,
        _ => Icons.settings_outlined,
      };

  // ── 液态档：接 GlassTabBar.bottom（指南 §6.2）─────────────────────────
  Widget _buildLiquidBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return lgw.GlassTabBar.bottom(
      tabs: [
        for (var i = 0; i < widget.tabs.length; i++)
          lgw.GlassTab(
            semanticLabel: widget.tabs[i],
            icon: _tabContent(context, i, false),
            activeIcon: _tabContent(context, i, true),
          ),
      ],
      selectedIndex: _visualIndex,
      onTabSelected: _handleTabSelected,
      extraButton: lgw.GlassTabBarExtraButton(
        icon: Icon(widget.extraIcon),
        onTap: widget.extraOnTap,
        label: widget.extraLabel,
        iconColor: cs.onSurface,
        size: GlassTokens.floatingActionSize, // 必须恒等于栏高
      ),
      horizontalPadding: 0,
      verticalPadding: 0,
      barHeight: GlassTokens.floatingTabBarHeight,
      barBorderRadius: GlassTokens.floatingTabBarHeight / 2,
      spacing: 12,
      settings: lgw.LiquidGlassSettings(
        glassColor: GlassTokens.widgetsTint(cs),
        visibility: 1,
        shadow: const [],
        blur: 5,
      ),
      quality: chromeGlassQuality,
      // ⭐ 静止时不画高亮底色，选中态只靠图标/文字变色（2026-09-15 拍板口径）
      indicatorColor: Colors.transparent,
      showIndicator: true,
    );
  }

  // ── Material 档：同一几何、M3 材质（指南 §6.5）─────────────────────────
  Widget _buildMaterialBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: GlassTokens.materialFill(cs),
      elevation: 0, // ⛔ 无投影："更浮"靠往上挑 surface container 色阶
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(GlassTokens.floatingTabBarHeight / 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: GlassTokens.floatingTabBarHeight,
        child: Row(
          children: [
            for (var i = 0; i < widget.tabs.length; i++)
              Expanded(
                child: _MaterialTab(
                  label: widget.tabs[i],
                  icon: _tabIcon(i),
                  selected: _visualIndex == i,
                  onTap: () => _handleTabSelected(i),
                ),
              ),
            SizedBox(width: 12),
            _MaterialCircleButton(
              size: GlassTokens.floatingActionSize,
              icon: widget.extraIcon,
              semanticLabel: widget.extraLabel,
              onTap: widget.extraOnTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _MaterialTab extends StatelessWidget {
  const _MaterialTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = selected ? 1.0 : 0.0;
    return InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: t),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        builder: (context, anim, _) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26,
                  color: Color.lerp(cs.onSurfaceVariant, cs.primary, anim)),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: Color.lerp(cs.onSurfaceVariant, cs.onSurface, anim),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MaterialCircleButton extends StatelessWidget {
  const _MaterialCircleButton({
    required this.size,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final double size;
  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size - 8,
            height: size,
            child: Icon(icon, size: 26, color: cs.onSurface),
          ),
        ),
      ),
    );
  }
}
