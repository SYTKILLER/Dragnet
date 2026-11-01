// 匹配自检页：按域名查询当前引擎判定（无网络副作用），渲染判定卡。
// 数据来自 UI 进程内引擎（RulesPage 进入时已 loadRules filesDir/rules）。

import { router, LengthMetrics } from '@kit.ArkUI';
import {
  matchDomain, MatchResult
} from '../common/DragnetService';

interface SampleChip {
  domain: string;
  expect: string; // 预期提示
}

@Entry
@Component
struct MatchTestPage {
  @State inputDomain: string = '';
  @State result: MatchResult | null = null;
  @State emptyNotice: string = '';

  private samples: SampleChip[] = [
    { domain: 'doubleclick.net', expect: '应阻断' },
    { domain: 'google-analytics.com', expect: '应阻断' },
    { domain: 'alipay.com', expect: '白名单放行' },
    { domain: 'baidu.com', expect: '未命中' }
  ];

  private query(domain: string): void {
    const d = domain.trim();
    this.inputDomain = d;
    if (d === '') {
      this.emptyNotice = '请输入域名';
      this.result = null;
      return;
    }
    this.result = matchDomain(d);
    this.emptyNotice = this.result === null ? '引擎空载：先在规则页加载规则' : '';
  }

  @Builder
  sampleChip(chip: SampleChip) {
    Text(`${chip.domain}（${chip.expect}）`)
      .fontSize(12)
      .fontColor($r('app.color.primary'))
      .backgroundColor($r('app.color.primary_soft'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => this.query(chip.domain))
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => router.back())
        Text('匹配自检')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 10 })
      }
      .width('92%')
      .margin({ top: 16 })

      Text('按域名查询当前引擎判定，不产生任何网络请求。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('92%')

      Row({ space: 8 }) {
        TextInput({ text: this.inputDomain, placeholder: '输入域名，如 example.com' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .onChange((value: string) => {
            this.inputDomain = value;
          })
        Button('查询')
          .height(42)
          .fontSize(15)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.query(this.inputDomain))
      }
      .width('92%')

      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(this.samples, (chip: SampleChip) => {
          this.sampleChip(chip)
        }, (chip: SampleChip) => chip.domain)
      }
      .width('92%')

      if (this.emptyNotice !== '') {
        Text(this.emptyNotice)
          .fontSize(13)
          .fontColor($r('app.color.warn'))
          .width('92%')
      }

      if (this.result !== null) {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Text(this.result.action === 'BLOCK' ? '⛔' :
              (this.result.action === 'ALLOW' ? '✅' : '➖'))
              .fontSize(28)
            Column({ space: 2 }) {
              Text(this.result.action === 'BLOCK' ? '阻断' :
                (this.result.action === 'ALLOW' ? '放行（白名单）' : '未命中'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.result.action === 'BLOCK' ? $r('app.color.danger') :
                  (this.result.action === 'ALLOW' ? $r('app.color.safe') : $r('app.color.text_secondary')))
              Text(this.inputDomain)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Divider().color($r('app.color.divider'))

          Column({ space: 6 }) {
            Text(`命中规则：${this.result.rule === '' ? '（无）' : this.result.rule}`)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text(`来源订阅：${this.result.list === '' ? '（无）' : this.result.list}`)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
