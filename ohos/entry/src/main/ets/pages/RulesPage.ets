// 规则页：规则规模（ruleInfo）+ 规则目录文件列表（List/ListItem）+ 重新加载
// + 匹配自检入口（NavPathStack 跳转，router 全面禁用）。
// 规范合规：
//   - List 直属子节点只能是 ListItem/ListItemGroup；ListItem 单子节点（内部包 Row）；
//   - ForEach keyGenerator 编入内容状态（文件名+体积，重载后同 key 不复用旧渲染）；
//   - 跳转一律 NavPathStack：pushPathByName + .catch(BusinessError) 落日志（不空吞）；
//   - 加载中用 LoadingProgress；路由栈经 AppStorage 获取（规范四法之一）；
//   - UI 进程也加载一份规则（filesDir/rules），供自检页做无副作用判定查询；
//     与 VPN 扩展进程的引擎实例互不影响。M4-R1：规则仅来自外部目录，无内嵌种子。

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  loadRulesDir, readRuleInfo, listRuleFiles, ruleFileSize,
  loadRulesErrorText, formatBytes, RuleInfo
} from '../common/DragnetService';

const DOMAIN = 0xD22E0;

interface RuleFileRow {
  name: string;
  sizeText: string;
}

@Component
export struct RulesPage {
  @State info: RuleInfo | null = null;
  @State files: RuleFileRow[] = [];
  @State reloadMsg: string = '';
  @State isLoading: boolean = false;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const rc: number = loadRulesDir(ctx.filesDir);
    this.reloadMsg = rc === 0 ? '' : loadRulesErrorText(rc);
    hilog.info(DOMAIN, 'Dragnet', '[UI] RulesPage loadRules rc=%{public}d', rc);
    this.info = readRuleInfo();
    this.refreshFiles();
  }

  private refreshFiles(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // @State 数组整体重建赋值（禁展开运算符，手写循环——ArkTS 语法红线）。
    const rows: RuleFileRow[] = [];
    for (const name of listRuleFiles(ctx.filesDir)) {
      const size = ruleFileSize(ctx.filesDir, name);
      rows.push({ name: name, sizeText: size >= 0 ? formatBytes(size) : '不可读' });
    }
    this.files = rows;
  }

  private reload(): void {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const rc: number = loadRulesDir(ctx.filesDir);
    this.isLoading = false;
    this.reloadMsg = loadRulesErrorText(rc);
    hilog.info(DOMAIN, 'Dragnet', '[UI] rules reload rc=%{public}d', rc);
    // 成功/失败都翻 @State（成功路径也必须翻，且被 build if 链读取）；
    // 失败不清文件列表（失败刷新不得先清列表——踩坑卡）。
    this.info = readRuleInfo();
    this.refreshFiles();
  }

  private openMatchTest(): void {
    const stack = AppStorage.get<NavPathStack>('dragnetPathStack');
    if (stack === undefined) {
      this.reloadMsg = '路由栈未就绪';
      hilog.error(DOMAIN, 'Dragnet', '[UI] openMatchTest failed: pathStack missing');
      return;
    }
    // pushPathByName 为同步 void；要拿 Promise（失败落日志，不空吞）用 pushDestinationByName。
    stack.pushDestinationByName('MatchTest', null).catch((err: BusinessError): void => {
      this.reloadMsg = '打开自检页失败: ' + err.message;
      hilog.error(DOMAIN, 'Dragnet', '[UI] pushDestinationByName MatchTest failed: %{public}s', err.message);
    });
  }

  build() {
    Column() {
      Text('规则管理')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('92%')
        .margin({ top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          // 规模卡
          Column({ space: 8 }) {
            Text('已加载规则规模')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            if (this.info !== null) {
              Row() {
                Column({ space: 4 }) {
                  Text(String(this.info.lists))
                    .fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.primary'))
                  Text('规则列表').fontSize(12).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Center)
                .layoutWeight(1)

                Column({ space: 4 }) {
                  Text(String(this.info.rule_lines))
                    .fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.primary'))
                  Text('规则行数').fontSize(12).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Center)
                .layoutWeight(1)

                Column({ space: 4 }) {
                  Text(formatBytes(this.info.rule_bytes))
                    .fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.primary'))
                  Text('规则体积').fontSize(12).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Center)
                .layoutWeight(1)
              }
              .width('100%')
            } else {
              Text('引擎空载：规则目录为空或尚未加载（fail-open，无任何规则生效）')
                .fontSize(13)
                .fontColor($r('app.color.warn'))
                .textAlign(TextAlign.Center)
                .width('100%')
            }
          }
          .width('92%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))

          // 文件列表卡（List/ListItem：直属子节点只能是 ListItem，ListItem 单子节点）
          Column({ space: 8 }) {
            Text('规则目录（filesDir/rules）')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            if (this.files.length === 0) {
              Text('（目录为空——种子规则随包分发，见设置页说明）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            } else {
              List() {
                ForEach(this.files, (f: RuleFileRow) => {
                  ListItem() {
                    Row() {
                      SymbolGlyph($r('sys.symbol.doc_text'))
                        .fontSize(16)
                        .fontColor([$r('app.color.text_secondary')])
                        .margin({ right: 8 })
                      Text(f.name)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      Text(f.sizeText)
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                    }
                    .width('100%')
                    .padding({ top: 10, bottom: 10 })
                    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
                  }
                }, (f: RuleFileRow) => `${f.name}|${f.sizeText}`)
              }
              .width('100%')
              .scrollBar(BarState.Off)
            }
          }
          .width('92%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))

          if (this.isLoading) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color($r('app.color.primary'))
              Text('正在加载…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('92%')
          } else if (this.reloadMsg !== '') {
            Text(this.reloadMsg)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('92%')
          }

          // 操作按钮（重载图标 arrow_counterclockwise / 自检 magnifyingglass）
          Row({ space: 12 }) {
            Button('重新加载')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .backgroundColor($r('app.color.primary'))
              .onClick(() => this.reload())
            Button('匹配自检')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .backgroundColor($r('app.color.primary_soft'))
              .fontColor($r('app.color.primary'))
              .onClick(() => this.openMatchTest())
          }
          .width('92%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 96 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
