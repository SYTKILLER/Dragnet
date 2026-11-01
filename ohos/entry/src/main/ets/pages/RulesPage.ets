// 规则页：规则规模（ruleInfo）+ 规则目录文件列表 + 重新加载 + 匹配自检入口。
// UI 进程也加载一份规则（filesDir/rules），供自检页做无副作用判定查询；
// 与 VPN 扩展进程的引擎实例互不影响。M4-R1：规则仅来自外部目录，无内嵌种子。

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  loadRulesDir, readRuleInfo, listRuleFiles, ruleFileSize,
  loadRulesErrorText, formatBytes, RuleInfo
} from '../common/DragnetService';

interface RuleFileRow {
  name: string;
  sizeText: string;
}

@Component
export struct RulesPage {
  @State info: RuleInfo | null = null;
  @State files: RuleFileRow[] = [];
  @State reloadMsg: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const rc: number = loadRulesDir(ctx.filesDir);
    this.reloadMsg = rc === 0 ? '' : loadRulesErrorText(rc);
    this.info = readRuleInfo();
    this.refreshFiles();
  }

  private refreshFiles(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const rows: RuleFileRow[] = [];
    for (const name of listRuleFiles(ctx.filesDir)) {
      const size = ruleFileSize(ctx.filesDir, name);
      rows.push({ name: name, sizeText: size >= 0 ? formatBytes(size) : '不可读' });
    }
    this.files = rows;
  }

  private reload(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const rc: number = loadRulesDir(ctx.filesDir);
    this.reloadMsg = loadRulesErrorText(rc);
    this.info = readRuleInfo();
    this.refreshFiles();
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

          // 文件列表卡
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
              ForEach(this.files, (f: RuleFileRow) => {
                Row() {
                  Text('📄').fontSize(16).margin({ right: 8 })
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
              }, (f: RuleFileRow) => f.name)
            }
          }
          .width('92%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))

          if (this.reloadMsg !== '') {
            Text(this.reloadMsg)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('92%')
          }

          // 操作按钮
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
              .onClick(() => {
                router.pushUrl({ url: 'pages/MatchTestPage' }).catch((err: Error): void => {
                  this.reloadMsg = '打开自检页失败: ' + err.message;
                });
              })
          }
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
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
