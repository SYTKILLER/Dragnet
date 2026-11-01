import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

/// 材质四档（复现指南 §4.1）。新界面不许自己包玻璃字面量，一律经
/// [GlassSurface] + 三个供档点收口。
enum GlassBackend {
  /// 传统档：半透明 fill + 0.6 描边，无 blur 无投影，零 shader 成本。
  /// 滚动容器内、不上玻璃的地方走这档。
  plain,

  /// M3 档：不透明 surfaceContainerHigh，无描边/投影/形变。
  material,

  /// easy 真折射透镜——浮出面板钉死这档。
  easyLens,

  /// widgets AdaptiveGlass——页面 chrome 走这档。
  liquidWidgets,
}

/// 全局用户开关：设置页"玻璃质感"，运行时生效不用重启。
enum GlassMaterialMode { material, liquid }

final ValueNotifier<GlassMaterialMode> glassMaterialMode =
    ValueNotifier<GlassMaterialMode>(GlassMaterialMode.liquid);

/// ⛔ 必须挂在 MaterialApp 之上（Navigator 之上），否则弹窗/菜单切档不重建。
class GlassMaterialScope extends InheritedNotifier<ValueNotifier<GlassMaterialMode>> {
  GlassMaterialScope({super.key, required super.child})
      : super(notifier: glassMaterialMode);

  static GlassMaterialMode of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassMaterialScope>()
          ?.notifier
          ?.value ??
      glassMaterialMode.value;

  static bool isLiquid(BuildContext context) =>
      of(context) == GlassMaterialMode.liquid;
}

/// ① 页面 chrome 供档：液态开关开 → widgets 档；否则 M3 档。
GlassBackend chromeGlassBackend(BuildContext context) => GlassMaterialScope.isLiquid(context)
    ? GlassBackend.liquidWidgets
    : GlassBackend.material;

/// ② 不上玻璃的地方（弹窗正文、滚动容器内）：液态开 → 传统便宜档。
GlassBackend flatGlassBackend(BuildContext context) =>
    GlassMaterialScope.isLiquid(context)
        ? GlassBackend.plain
        : GlassBackend.material;

/// ③ 浮出面板供档（挂在根 Overlay，无角色约束）：钉死 easy，不跟触发件走。
GlassBackend panelGlassBackend(BuildContext anchorContext) =>
    GlassMaterialScope.isLiquid(anchorContext)
        ? GlassBackend.easyLens
        : GlassBackend.material;

/// 画质档（指南 §1.3）：Windows/Linux 钉 standard（shader 现编译首屏白窗）；
/// Android/iOS Impeller 走 premium。
lgw.GlassQuality get chromeGlassQuality => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux => lgw.GlassQuality.standard,
      _ => lgw.GlassQuality.premium,
    };
