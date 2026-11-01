// 匹配自检页（NavDestination + 系统路由表，router_map.json 注册）：
//   按域名查询当前引擎判定（无网络副作用），渲染判定卡。
// 规范合规：
//   - 系统返回键（.title()），禁止自绘返回按钮；
//   - 内容区不加顶部 padding（原生标题栏下自带偏移，踩坑卡）；
//   - Search 组件替代 TextInput（原生搜索框，自带清除按钮）；
//   - 判定图标 SymbolGlyph（禁 emoji）。
// 数据来自 UI 进程内引擎（RulesPage 进入时已 loadRules filesDir/rules）。

import { LengthMetrics } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { matchDomain, MatchResult } from '../common/DragnetService';

const DOMAIN = 0xD22E0;

interface SampleChip {
  domain: string;
  expect: string;
}

// 系统路由表入口函数：名字必须与 router_map.json 的 buildFunction 完全一致。
@Builder
export function MatchTestPageBuilder() {
  MatchTestPage()
}

@Component
struct MatchTestPage {
  @State inputDomain: string = '';
  @State result: MatchResult | null = null;
  @State emptyNotice: string = '';
  private pathStack: NavPathStack | null = null;

  // onReady 是 NavDestination 标准入页点：取路由栈（本页仅系统返回键即可返回，
  // 保留栈引用备用，不做自绘返回）。
  onReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx.pathStack;
    hilog.info(DOMAIN, 'Dragnet', '[UI] MatchTest onReady');
  }

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
    hilog.info(DOMAIN, 'Dragnet', '[UI] match query %{public}s done', d);
  }

  private verdictAction(): Resource {
    // $r 资源名必须字符串字面量（禁插值）——if/else 分支切换（规范）。
    if (this.result !== null && this.result.action === 'BLOCK') {
      return $r('sys.symbol.xmark');
    }
    if (this.result !== null && this.result.action === 'ALLOW') {
      return $r('sys.symbol.checkmark_circle_fill');
    }
    return $r('sys.symbol.minus');
  }

  private verdictColor(): ResourceColor {
    if (this.result !== null && this.result.action === 'BLOCK') {
      return $r('app.color.danger');
    }
    if (this.result !== null && this.result.action === 'ALLOW') {
      return $r('app.color.safe');
    }
    return $r('app.color.text_secondary');
  }

  private verdictLabel(): string {
    if (this.result !== null && this.result.action === 'BLOCK') {
      return '阻断';
    }
    if (this.result !== null && this.result.action === 'ALLOW') {
      return '放行（白名单）';
    }
    return '未命中';
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
    NavDestination() {
      Column({ space: 14 }) {
        Text('按域名查询当前引擎判定，不产生任何网络请求。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('92%')

        Search({ value: this.inputDomain, placeholder: '输入域名，如 example.com' })
          .width('92%')
          .height(42)
          .backgroundColor($r('app.color.card_bg'))
          .onChange((value: string) => {
            this.inputDomain = value;
          })
          .onSubmit((value: string) => {
            this.query(value);
          })

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
              SymbolGlyph(this.verdictAction())
                .fontSize(28)
                .fontColor([this.verdictColor()])
              Column({ space: 2 }) {
                Text(this.verdictLabel())
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.verdictColor())
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
      .alignItems(HorizontalAlign.Center)
      // 底部留白（规范：短内容不强行撑高，留系统导航条空间即可）。
      .padding({ bottom: 24 })
    }
    .title('匹配自检')
    .backgroundColor($r('app.color.app_bg'))
  }

  private samples: SampleChip[] = [
    { domain: 'doubleclick.net', expect: '应阻断' },
    { domain: 'google-analytics.com', expect: '应阻断' },
    { domain: 'alipay.com', expect: '白名单放行' },
    { domain: 'baidu.com', expect: '未命中' }
  ];
}
