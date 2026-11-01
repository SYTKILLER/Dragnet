// 运行统计页：内核 7 项计数器 + 运行时长（跨进程状态桥轮询）。

import { common } from '@kit.AbilityKit';
import { readVpnSnapshot, formatUptime, VpnSnapshot, RunStats } from '../common/DragnetService';

@Component
export struct StatsPage {
  @State snapshot: VpnSnapshot = { running: false, stats: null, lastTs: 0 };
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
    const ctx = getContext(this) as common.UIAbilityContext;
    this.snapshot = readVpnSnapshot(ctx.filesDir);
  }

  @Builder
  counterCell(label: string, value: number, valueColor: ResourceColor) {
    Column({ space: 6 }) {
      Text(String(value))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(valueColor)
        .maxLines(1)
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('46%')
    .padding({ top: 16, bottom: 16 })
    .borderRadius(14)
    .backgroundColor($r('app.color.card_bg'))
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
        Scroll() {
          Column({ space: 12 }) {
            Text(`内核已运行 ${formatUptime((this.snapshot.stats as RunStats).uptime_sec)}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))

            Row() {
              this.counterCell('DNS 阻断', (this.snapshot.stats as RunStats).dns_blocked, $r('app.color.danger'))
              this.counterCell('DNS 放行', (this.snapshot.stats as RunStats).dns_forwarded, $r('app.color.safe'))
            }
            .justifyContent(FlexAlign.SpaceBetween)
            .width('92%')

            Row() {
              this.counterCell('TCP 阻断', (this.snapshot.stats as RunStats).tcp_blocked, $r('app.color.danger'))
              this.counterCell('TCP 转发', (this.snapshot.stats as RunStats).tcp_relayed, $r('app.color.text_primary'))
            }
            .justifyContent(FlexAlign.SpaceBetween)
            .width('92%')

            Row() {
              this.counterCell('UDP 阻断', (this.snapshot.stats as RunStats).udp_blocked, $r('app.color.danger'))
              this.counterCell('UDP 转发', (this.snapshot.stats as RunStats).udp_relayed, $r('app.color.text_primary'))
            }
            .justifyContent(FlexAlign.SpaceBetween)
            .width('92%')

            // IP↔域名缓存整行
            Row() {
              Column({ space: 6 }) {
                Text(String((this.snapshot.stats as RunStats).cache))
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.primary'))
                Text('IP↔域名有界缓存条目')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .width('92%')
            .padding({ top: 16, bottom: 16 })
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))

            Text('统计每 2 秒经 VPN 扩展进程落盘同步（state/stats.json），UI 侧只读。')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('92%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      } else {
        Column({ space: 10 }) {
          Text('📊')
            .fontSize(44)
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
