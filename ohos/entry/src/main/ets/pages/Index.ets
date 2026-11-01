// 罗网正式壳 UI 入口（v2.0 标准化重构）：
//   Navigation root（全应用唯一 @Entry，NavBar = HdsTabs 四 Tab 首页）
//   + 系统路由表（router_map.json）子页。
// 规范合规（docs/hmos-dev/30-规范）：
//   - router 全面禁用：路由全走 NavPathStack（全局声明类，禁止从 @kit.ArkUI 导入），
//     跨组件经 AppStorage 传递（规范四法之一）；
//   - 图标一律 SymbolGlyph（TabBarSymbol normal/selected SymbolGlyphModifier 对，
//     着色经 applyNormalAttribute——以本地 SDK d.ts 为准，无 fontColor 方法面）；
//   - 颜色一律 $r('app.color.*')（base+dark 双色板）；
//   - HdsTabs 坑：单 controller 不复用；gradientMask 默认近白蒙层必须透明化
//     （maskColor #00000000，maskHeight 不可为 0）。

import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DashboardPage } from './DashboardPage';
import { StatsPage } from './StatsPage';
import { RulesPage } from './RulesPage';
import { SettingsPage } from './SettingsPage';

const DOMAIN = 0xD22E0;

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  private pathStack: NavPathStack = new NavPathStack();
  private hdsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    // 跨组件路由栈传递（规范：AppStorage 法）。RulesPage pushPathByName('MatchTest')。
    AppStorage.setOrCreate('dragnetPathStack', this.pathStack);
    hilog.info(DOMAIN, 'Dragnet', '[UI] Index aboutToAppear, pathStack ready');
  }

  // tab 图标着色：SymbolGlyphModifier 继承 SymbolGlyphAttribute 的 fontColor
  //（本地 d.ts 实证，继承方法链式调用）。
  private tabIcon(res: Resource, color: ResourceColor): SymbolGlyphModifier {
    return new SymbolGlyphModifier(res).fontColor([color]);
  }

  private tabBarIcon(normal: Resource, selected: Resource): TabBarSymbol {
    const sym: TabBarSymbol = {
      normal: this.tabIcon(normal, $r('app.color.text_secondary')),
      selected: this.tabIcon(selected, $r('app.color.primary'))
    };
    return sym;
  }

  build() {
    Navigation(this.pathStack) {
      HdsTabs({
        barPosition: BarPosition.End,
        index: this.currentIndex,
        controller: this.hdsController
      }) {
        TabContent() {
          DashboardPage()
        }
        .tabBar(BottomTabBarStyle.of(
          this.tabBarIcon($r('sys.symbol.house'), $r('sys.symbol.house_fill')),
          $r('app.string.tab_dashboard') as ResourceStr))

        TabContent() {
          StatsPage()
        }
        .tabBar(BottomTabBarStyle.of(
          this.tabBarIcon($r('sys.symbol.data_proportion'), $r('sys.symbol.data_proportion_fill')),
          $r('app.string.tab_stats') as ResourceStr))

        TabContent() {
          RulesPage()
        }
        .tabBar(BottomTabBarStyle.of(
          this.tabBarIcon($r('sys.symbol.doc_text'), $r('sys.symbol.doc_plaintext')),
          $r('app.string.tab_rules') as ResourceStr))

        TabContent() {
          SettingsPage()
        }
        .tabBar(BottomTabBarStyle.of(
          this.tabBarIcon($r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill')),
          $r('app.string.tab_settings') as ResourceStr))
      }
      .scrollable(false)
      .barOverlap(true)
      .barFloatingStyle({
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        // 默认近白蒙层会在浅色下出"底部白带"（踩坑卡），透明化；高度不可为 0。
        gradientMask: { maskColor: '#00000000', maskHeight: 72 }
      })
      .onSelected((index: number) => {
        this.currentIndex = index;
        hilog.info(DOMAIN, 'Dragnet', '[UI] tab selected: %{public}d', index);
      })
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
  }
}
