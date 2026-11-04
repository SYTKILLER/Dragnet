// 规则页（v2 重制）：不再展示规则文件列表，改为展示**具体规则内容**（用户规则，
// 哪些域名被拦截/放行）+ 引擎规模卡 + 重新加载/匹配自检入口（上移至规则列表上方）。
//
// 用户规则（filesDir/rules/zzz-user-rules.txt，格式/文件名与 Android 壳 M5-A 一致）：
//   - ListItem 展示单条规则（域名 + 拦截/放行标签 + 停用标记），右侧 Toggle 启停；
//   - 卡片头部「+」圆钮 → bindSheet 半模态编辑页新建规则；滑动条目出现
//     编辑（蓝底白 symbol，16vp 圆）/删除（红底白 symbol，16vp 圆）；
//   - 删除需 AlertDialog 二次确认；编辑/新建均点「保存」才覆写/落盘；
//   - 每次变更即时写文件 + 重载本页引擎实例（自检即时生效）；
//     VPN 扩展进程的引擎在下次 startVpn 时加载新规则（页面有提示文案）。
//
// 规范合规（docs/hmos-dev/30-规范）：
//   - List 直属子节点只能是 ListItem/ListItemGroup；ListItem 单子节点（内部包 Row）；
//   - ForEach keyGenerator 编入内容状态（域名+类型+启用态，启停后同域行重建渲染）；
//   - 图标一律 SymbolGlyph（禁 emoji / 图片图标）；颜色一律 $r('app.color.*')；
//   - AlertDialog 用 getUIContext().showAlertDialog（API 18 后全局 show 已废弃）；
//   - bindSheet isShow 走 $$ 双向绑定（下拉关闭自动回写 @State）；
//   - Toggle onChange 与程序回显幂等（同值跳过，防重放翻转）。

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  loadRulesDir, readRuleInfo, loadRulesErrorText, formatBytes, RuleInfo
} from '../common/DragnetService';
import {
  UserRuleKind, UserRuleEntry, listUserRules,
  addUserRule, updateUserRule, deleteUserRule, toggleUserRule
} from '../common/UserRulesService';

const DOMAIN = 0xD22E0;

@Component
export struct RulesPage {
  @State info: RuleInfo | null = null;
  @State entries: UserRuleEntry[] = [];
  @State statusMsg: string = '';
  @State statusIsError: boolean = false;
  // bindSheet 编辑态：editingLine=-1 新建；>=0 为 zzz-user-rules.txt 的行号
  @State sheetShow: boolean = false;
  @State editingLine: number = -1;
  @State inputDomain: string = '';
  @State inputKind: UserRuleKind = UserRuleKind.BLOCK;
  @State inputError: string = '';

  aboutToAppear(): void {
    // 进页静默加载：引擎装载 + 条目/规模刷新；失败才提示（成功不喧哗）
    const rc: number = loadRulesDir(this.filesDir());
    this.info = readRuleInfo();
    this.entries = listUserRules(this.filesDir());
    if (rc !== 0) {
      this.statusIsError = true;
      this.statusMsg = loadRulesErrorText(rc);
    }
    hilog.info(DOMAIN, 'Dragnet', '[UI] RulesPage aboutToAppear loadRules rc=%{public}d, userRules=%{public}d',
      rc, this.entries.length);
  }

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return ctx.filesDir;
  }

  /** 全量刷新：引擎重载 + 条目 + 规模；opText 非空时在状态行回显操作结论。 */
  private refreshAll(opText: string): void {
    const rc: number = loadRulesDir(this.filesDir());
    this.info = readRuleInfo();
    this.entries = listUserRules(this.filesDir());
    if (opText !== '') {
      this.statusIsError = rc !== 0;
      this.statusMsg = rc === 0
        ? opText + '，已重载引擎'
        : opText + '；引擎重载失败：' + loadRulesErrorText(rc);
    }
    hilog.info(DOMAIN, 'Dragnet', '[UI] rules %{public}s: loadRules rc=%{public}d, userRules=%{public}d',
      opText === '' ? 'reload' : opText, rc, this.entries.length);
  }

  /** 仅刷新条目列表（不动引擎；用于失败后回滚 Toggle 视觉）。 */
  private refreshEntries(): void {
    this.entries = listUserRules(this.filesDir());
  }

  private reload(): void {
    this.refreshAll('已重新加载');
  }

  private openMatchTest(): void {
    const stack = AppStorage.get<NavPathStack>('dragnetPathStack');
    if (stack === undefined) {
      this.statusIsError = true;
      this.statusMsg = '路由栈未就绪';
      hilog.error(DOMAIN, 'Dragnet', '[UI] openMatchTest failed: pathStack missing');
      return;
    }
    // pushPathByName 为同步 void；要拿 Promise（失败落日志，不空吞）用 pushDestinationByName。
    stack.pushDestinationByName('MatchTest', null).catch((err: BusinessError): void => {
      this.statusIsError = true;
      this.statusMsg = '打开自检页失败: ' + err.message;
      hilog.error(DOMAIN, 'Dragnet', '[UI] pushDestinationByName MatchTest failed: %{public}s', err.message);
    });
  }

  // ---- bindSheet 编辑 ----

  private openNewSheet(): void {
    this.editingLine = -1;
    this.inputDomain = '';
    this.inputKind = UserRuleKind.BLOCK;
    this.inputError = '';
    this.sheetShow = true;
  }

  private openEditSheet(entry: UserRuleEntry): void {
    this.editingLine = entry.lineIndex;
    this.inputDomain = entry.domain;
    this.inputKind = entry.kind;
    this.inputError = '';
    this.sheetShow = true;
  }

  private closeSheet(): void {
    this.sheetShow = false;
  }

  /** 保存：只有点击「保存」才覆写原规则/创建新规则；校验失败在表单内红字提示。 */
  private saveSheet(): void {
    const isEdit: boolean = this.editingLine >= 0;
    const res = isEdit
      ? updateUserRule(this.filesDir(), this.editingLine, this.inputDomain, this.inputKind)
      : addUserRule(this.filesDir(), this.inputDomain, this.inputKind);
    if (res.code !== 0) {
      this.inputError = res.message;
      hilog.info(DOMAIN, 'Dragnet', '[UI] rule save rejected code=%{public}d', res.code);
      return;
    }
    this.sheetShow = false;
    this.refreshAll(isEdit ? '已保存修改' : '已新增规则');
  }

  // ---- 启停 / 删除 ----

  private onToggle(entry: UserRuleEntry, on: boolean): void {
    if (on === entry.enabled) {
      return; // 程序回显或重复事件：同值跳过，防重放翻转
    }
    const res = toggleUserRule(this.filesDir(), entry.lineIndex, on);
    if (res.code !== 0) {
      this.statusIsError = true;
      this.statusMsg = res.message;
      this.refreshEntries(); // 失败：条目重读，Toggle 视觉回滚
      return;
    }
    this.refreshAll(on ? '已启用规则' : '已停用规则');
  }

  /** 删除二次确认（AlertDialog）；确认后才真正删除。 */
  private confirmDelete(entry: UserRuleEntry): void {
    this.getUIContext().showAlertDialog({
      title: '删除规则',
      message: `确定删除对「${entry.domain}」的${entry.kind === UserRuleKind.ALLOW ? '放行' : '拦截'}规则吗？删除后将从规则文件移除并立即重载引擎。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
          hilog.info(DOMAIN, 'Dragnet', '[UI] rule delete canceled: %{public}s', entry.domain);
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: (): void => {
          const res = deleteUserRule(this.filesDir(), entry.lineIndex);
          if (res.code !== 0) {
            this.statusIsError = true;
            this.statusMsg = res.message;
            this.refreshEntries();
            return;
          }
          this.refreshAll('已删除规则');
        }
      }
    });
  }

  // ---- 渲染辅助 ----

  private kindColor(kind: UserRuleKind): Resource {
    if (kind === UserRuleKind.ALLOW) {
      return $r('app.color.safe');
    }
    return $r('app.color.danger');
  }

  private kindSoftColor(kind: UserRuleKind): Resource {
    if (kind === UserRuleKind.ALLOW) {
      return $r('app.color.safe_soft');
    }
    return $r('app.color.danger_soft');
  }

  /** 滑动操作区：编辑（蓝底白 symbol）/删除（红底白 symbol），16vp 直径圆钮。 */
  @Builder
  rowActions(entry: UserRuleEntry) {
    Row({ space: 8 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.pencil_tip'))
          .fontSize(11)
          .fontColor([$r('app.color.text_on_action')])
      }
      .width(16)
      .height(16)
      .borderRadius(8)
      .backgroundColor($r('app.color.edit_blue'))
      .onClick(() => this.openEditSheet(entry))

      Stack() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(11)
          .fontColor([$r('app.color.text_on_action')])
      }
      .width(16)
      .height(16)
      .borderRadius(8)
      .backgroundColor($r('app.color.danger'))
      .onClick(() => this.confirmDelete(entry))
    }
    .height('100%')
    .padding({ left: 4, right: 12 })
  }

  /** 单条用户规则行：类型图标 + 域名/标签列 + 启停 Toggle。 */
  @Builder
  ruleRow(entry: UserRuleEntry) {
    Row({ space: 10 }) {
      SymbolGlyph(entry.kind === UserRuleKind.ALLOW
        ? $r('sys.symbol.checkmark_circle_fill')
        : $r('sys.symbol.xmark'))
        .fontSize(20)
        .fontColor([entry.enabled ? this.kindColor(entry.kind) : $r('app.color.text_secondary')])

      Column({ space: 3 }) {
        Text(entry.domain)
          .fontSize(15)
          .fontColor(entry.enabled ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 6 }) {
          Text(entry.kind === UserRuleKind.ALLOW ? '放行' : '拦截')
            .fontSize(10)
            .fontColor(this.kindColor(entry.kind))
            .backgroundColor(this.kindSoftColor(entry.kind))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(10)
          if (!entry.enabled) {
            Text('已停用')
              .fontSize(10)
              .fontColor($r('app.color.warn'))
              .backgroundColor($r('app.color.app_bg'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(10)
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: entry.enabled })
        .selectedColor($r('app.color.primary'))
        .onChange((on: boolean) => this.onToggle(entry, on))
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 2, right: 2 })
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }

  /** bindSheet 编辑页：新建/编辑共用；保存才落盘，下拉关闭/取消不产生任何写入。 */
  @Builder
  ruleSheetBuilder() {
    Column({ space: 14 }) {
      Text(this.editingLine >= 0 ? '编辑规则' : '新建规则')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      TextInput({ text: this.inputDomain, placeholder: '输入域名，如 ads.example.com' })
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderFont({ size: 14 })
        .backgroundColor($r('app.color.app_bg'))
        .borderRadius(12)
        .width('100%')
        .onChange((value: string) => {
          this.inputDomain = value;
        })

      Text('拦截：该域名的请求将被丢弃；放行：写入 $important 白名单例外，优先于订阅阻断。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 10 }) {
        Text('拦截')
          .fontSize(14)
          .fontColor(this.inputKind === UserRuleKind.BLOCK
            ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .backgroundColor(this.inputKind === UserRuleKind.BLOCK
            ? $r('app.color.danger_soft') : $r('app.color.app_bg'))
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .borderRadius(16)
          .onClick(() => {
            this.inputKind = UserRuleKind.BLOCK;
          })
        Text('放行')
          .fontSize(14)
          .fontColor(this.inputKind === UserRuleKind.ALLOW
            ? $r('app.color.safe') : $r('app.color.text_secondary'))
          .backgroundColor(this.inputKind === UserRuleKind.ALLOW
            ? $r('app.color.safe_soft') : $r('app.color.app_bg'))
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .borderRadius(16)
          .onClick(() => {
            this.inputKind = UserRuleKind.ALLOW;
          })
      }
      .width('100%')

      if (this.inputError !== '') {
        Text(this.inputError)
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }

      Blank().layoutWeight(1)

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.primary_soft'))
          .fontColor($r('app.color.primary'))
          .onClick(() => this.closeSheet())
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.text_on_primary'))
          .onClick(() => this.saveSheet())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 32 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Text('规则管理')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('92%')
        .margin({ top: 16, bottom: 12 })

      if (this.statusMsg !== '') {
        Text(this.statusMsg)
          .fontSize(13)
          .fontColor(this.statusIsError ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .width('92%')
          .margin({ bottom: 8 })
      }

      // 规模卡（引擎当前加载规模，含种子/订阅；用户规则启停后随之变化）
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

      // 操作按钮（上移至规则列表上方）：重新加载 / 匹配自检
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
      .margin({ top: 2 })

      // 用户规则卡：具体规则内容列表（拦截/放行哪些域名）
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Text('用户规则')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`（${this.entries.length}）`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Button() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(18)
              .fontColor([$r('app.color.text_on_primary')])
          }
          .width(32)
          .height(32)
          .type(ButtonType.Circle)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.openNewSheet())
        }
        .width('100%')

        if (this.entries.length === 0) {
          Column({ space: 4 }) {
            Text('暂无用户规则')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Text('点击右上角 + 新增拦截或放行规则')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 28, bottom: 28 })
        } else {
          List() {
            ForEach(this.entries, (entry: UserRuleEntry) => {
              ListItem() {
                this.ruleRow(entry)
              }
              .swipeAction({ end: this.rowActions(entry) })
            }, (entry: UserRuleEntry) => `${entry.domain}|${entry.kind}|${entry.enabled ? '1' : '0'}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ bottom: 96 }) // HdsTabs 悬浮页签条避让（≥28vp，取页面惯用 96）
        }

        Text('修改即时写入 zzz-user-rules.txt 并重载本页引擎（自检即时生效）；VPN 运行中需重启拦截后生效。')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('92%')
      .layoutWeight(1)
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 12, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .bindSheet($$this.sheetShow, this.ruleSheetBuilder(), {
      detents: [SheetSize.MEDIUM],
      showClose: false
    })
  }
}
