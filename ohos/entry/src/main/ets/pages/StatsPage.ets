// 运行统计页：内核 7 项计数器（Grid 纯 fr 模板）+ Refresh 下拉刷新。
// 规范合规：
//   - Grid rowsTemplate/columnsTemplate 只用纯 fr（混 vp 单位整网格塌陷——踩坑卡）；
//   - 计数单元格抽子组件 @Prop（@Builder 按值传参不刷新）；
//   - Refresh 的 refreshing @State 必须被 build 的 if 链真实读取（刷新依赖三规则）；
//   - 颜色全 $r('app.color.*')；定时器 aboutToDisappear 必清。

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readVpnSnapshot, formatUptime, VpnSnapshot, RunStats } from '../common/DragnetService';

const DOMAIN = 0xD22E0;

// 计数单元格：数据经 @Prop 单向同步。
@Component
struct CounterCell {
  @Prop label: string = '';
  @Prop value: string = '0';
  @Prop valueColor: ResourceColor = $r('app.color.text_primary');

  build() {
    Column({ space: 6 }) {
      Text(this.value)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.valueColor)
        .maxLines(1)
      Text(this.label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .borderRadius(14)
    .backgroundColor($r('app.color.card_bg'))
  }
}

@Component
export struct StatsPage {
  @State snapshot: VpnSnapshot = { running: false, stats: null, lastTs: 0, errorRc: 0, errMsg: '' };
  @State isRefreshing: boolean = false;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timerId = setInterval((): void => this.refresh(), 2000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refresh(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.snapshot = readVpnSnapshot(ctx.filesDir);
    hilog.info(DOMAIN, 'Dragnet', '[UI] stats snapshot refreshed, running=%{public}s',
      String(this.snapshot.running));
  }

  // 下拉刷新：手动触发一次读取后收起刷新态（isRefreshing 在 build 的 if 链中
  // 真实读取，保证刷新依赖成立）。
  private onPullRefresh(): void {
    this.refresh();
    this.isRefreshing = false;
  }

  build() {
    Column() {
      Text('运行统计')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('92%')
        .margin({ top: 16, bottom: 12 })

      if (this.snapshot.running && this.snapshot.stats !== null) {
        Refresh({ refreshing: this.isRefreshing }) {
          Column({ space: 12 }) {
            Text(`内核已运行 ${formatUptime((this.snapshot.stats as RunStats).uptime_sec)}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 8 })

            // 纯 fr 模板（规范：固定高度内容移出 Grid；Grid 自带滚动，不嵌 Scroll）
            Grid() {
                GridItem() {
                  CounterCell({
                    label: 'DNS 阻断',
                    value: String((this.snapshot.stats as RunStats).dns_blocked),
                    valueColor: $r('app.color.danger')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'DNS 放行',
                    value: String((this.snapshot.stats as RunStats).dns_forwarded),
                    valueColor: $r('app.color.safe')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'TCP 阻断',
                    value: String((this.snapshot.stats as RunStats).tcp_blocked),
                    valueColor: $r('app.color.danger')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'TCP 转发',
                    value: String((this.snapshot.stats as RunStats).tcp_relayed),
                    valueColor: $r('app.color.text_primary')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'UDP 阻断',
                    value: String((this.snapshot.stats as RunStats).udp_blocked),
                    valueColor: $r('app.color.danger')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'UDP 转发',
                    value: String((this.snapshot.stats as RunStats).udp_relayed),
                    valueColor: $r('app.color.text_primary')
                  })
                }
                GridItem() {
                  CounterCell({
                    label: 'IP↔域名有界缓存条目',
                    value: String((this.snapshot.stats as RunStats).cache),
                    valueColor: $r('app.color.primary')
                  })
                }
              }
              .columnsTemplate('1fr 1fr')
              .rowsGap(12)
              .columnsGap(12)
              .width('92%')
              .layoutWeight(1)

              Text('统计每 2 秒经 VPN 扩展进程落盘同步（state/stats.json），UI 侧只读；下拉可立即刷新。')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('92%')
                .padding({ bottom: 8 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .height('100%')
            .padding({ bottom: 96 })
        }
        .onRefreshing(() => this.onPullRefresh())
        .width('100%')
        .layoutWeight(1)
      } else {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.data_proportion'))
            .fontSize(44)
            .fontColor([$r('app.color.text_secondary')])
          Text('内核未运行')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
          Text('在首页启动拦截后，这里会显示 DNS/TCP/UDP 各通道的实时计数。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width('80%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
