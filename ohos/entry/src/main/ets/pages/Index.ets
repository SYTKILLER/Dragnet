// 罗网正式壳 UI 入口：底部四 Tab（首页/统计/规则/设置）。
// 匹配自检为规则页的子页（pages/MatchTestPage，router 跳转）。

import { DashboardPage } from './DashboardPage';
import { StatsPage } from './StatsPage';
import { RulesPage } from './RulesPage';
import { SettingsPage } from './SettingsPage';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;

  @Builder
  tabBar(label: ResourceStr, index: number) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.currentIndex === index ? $r('app.color.primary') : $r('app.color.text_secondary'))
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        DashboardPage()
      }
      .tabBar(this.tabBar($r('app.string.tab_dashboard'), 0))

      TabContent() {
        StatsPage()
      }
      .tabBar(this.tabBar($r('app.string.tab_stats'), 1))

      TabContent() {
        RulesPage()
      }
      .tabBar(this.tabBar($r('app.string.tab_rules'), 2))

      TabContent() {
        SettingsPage()
      }
      .tabBar(this.tabBar($r('app.string.tab_settings'), 3))
    }
    .scrollable(false)
    .barHeight(56)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
  }
}
