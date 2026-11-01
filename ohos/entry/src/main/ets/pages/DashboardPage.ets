// 首页仪表盘：VPN 运行状态（轮询跨进程状态文件）+ 拦截开关 + 拦截概览。
// 规范合规：
//   - 动态内容抽子组件 @Prop（@Builder 按值传参不刷新——踩坑卡定案）；
//   - 图标一律 SymbolGlyph（禁 emoji）；
//   - 颜色一律 $r('app.color.*')，阴影色资源化；
//   - 定时器 aboutToDisappear 必清；点击先给同步反馈（Promise 可能不落定）。
// 统计数据来自 filesDir/state/stats.json（VpnExtAbility 每 2s 落盘），
// 不直接调 stats()——UI 进程与 VPN 扩展不同进程，stats() 恒为空。

import { vpnExtension } from '@kit.NetworkKit';
import { Want, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readVpnSnapshot, formatUptime, VpnSnapshot } from '../common/DragnetService';

const DOMAIN = 0xD22E0;

// 概览磁贴子组件：数据经 @Prop 单向同步（规范：@Builder 按值传参会冻结首帧）。
@Component
struct StatTile {
  @Prop label: string = '';
  @Prop value: string = '0';
  @Prop valueColor: ResourceColor = $r('app.color.text_primary');

  build() {
    Column({ space: 4 }) {
      Text(this.value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.valueColor)
      Text(this.label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct DashboardPage {
  @State snapshot: VpnSnapshot = { running: false, stats: null, lastTs: 0 };
  @State actionMsg: string = '';
  private timerId: number = -1;
  private vpnWant: Want = {
    deviceId: '',
    bundleName: 'com.march.dragnet',
    abilityName: 'VpnExtAbility'
  };

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
  }

  private startBlock(): void {
    // 即时反馈：startVpnExtensionAbility 的 Promise 在授权对话框缺失/等待期间
    // 可能长时间不落定（模拟器实测 netmanager 每 10s 重试 vpndialog），
    // 若只依赖 then/catch 用户会以为点击无效。
    this.actionMsg = '正在启动…（首次会弹系统授权对话框）';
    hilog.info(DOMAIN, 'Dragnet', '[UI] startVpnExtensionAbility begin');
    vpnExtension.startVpnExtensionAbility(this.vpnWant).then((): void => {
      this.actionMsg = 'VPN 扩展启动成功（首次会弹系统授权对话框）';
      hilog.info(DOMAIN, 'Dragnet', '[UI] startVpnExtensionAbility ok');
    }).catch((err: BusinessError): void => {
      this.actionMsg = `启动失败: code=${err.code} ${err.message}`;
      hilog.error(DOMAIN, 'Dragnet', '[UI] startVpnExtensionAbility failed: %{public}s', err.message);
    });
  }

  private stopBlock(): void {
    this.actionMsg = '正在停止…';
    hilog.info(DOMAIN, 'Dragnet', '[UI] stopVpnExtensionAbility begin');
    vpnExtension.stopVpnExtensionAbility(this.vpnWant).then((): void => {
      this.actionMsg = 'VPN 扩展已停止';
      hilog.info(DOMAIN, 'Dragnet', '[UI] stopVpnExtensionAbility ok');
    }).catch((err: BusinessError): void => {
      this.actionMsg = `停止失败: code=${err.code} ${err.message}`;
      hilog.error(DOMAIN, 'Dragnet', '[UI] stopVpnExtensionAbility failed: %{public}s', err.message);
    });
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 顶部标题
        Row() {
          Text('罗网')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(' Dragnet')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 6, top: 8 })
        }
        .width('100%')
        .margin({ top: 16 })

        // 状态主卡（图标 SymbolGlyph：checkmark_shield_fill 运行 / security_shield 未运行）
        Column({ space: 12 }) {
          if (this.snapshot.running) {
            SymbolGlyph($r('sys.symbol.checkmark_shield_fill'))
              .fontSize(56)
              .fontColor([$r('app.color.safe')])
          } else {
            SymbolGlyph($r('sys.symbol.security_shield'))
              .fontSize(56)
              .fontColor([$r('app.color.text_secondary')])
          }
          Text(this.snapshot.running ? $r('app.string.state_running') : $r('app.string.state_stopped'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.snapshot.running ? $r('app.color.safe') : $r('app.color.text_secondary'))
            .backgroundColor(this.snapshot.running ? $r('app.color.safe_soft') : $r('app.color.divider'))
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .borderRadius(20)
          if (this.snapshot.running && this.snapshot.stats !== null) {
            Text(`已运行 ${formatUptime(this.snapshot.stats.uptime_sec)}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('92%')
        .padding({ top: 28, bottom: 28 })
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .shadow({ radius: 12, color: $r('app.color.card_shadow'), offsetY: 2 })

        // 开关（启动 play_fill / 停止 stop_circle_fill，SymbolGlyph 图标随按钮）
        if (this.snapshot.running) {
          Button($r('app.string.btn_stop_block'))
            .width('92%')
            .height(48)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .type(ButtonType.Capsule)
            .backgroundColor($r('app.color.danger'))
            .onClick(() => this.stopBlock())
        } else {
          Button($r('app.string.btn_start_block'))
            .width('92%')
            .height(48)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .type(ButtonType.Capsule)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.startBlock())
        }

        // DNS 阻断/放行占比（DataPanel 环形，标准 ArkUI 组件）
        Row({ space: 14 }) {
          DataPanel({
            values: [
              this.snapshot.stats !== null ? this.snapshot.stats.dns_blocked : 0,
              this.snapshot.stats !== null ? this.snapshot.stats.dns_forwarded : 0
            ],
            max: 100,
            type: DataPanelType.Circle
          })
            .width(72)
            .height(72)

          Column({ space: 6 }) {
            Text('DNS 查询占比')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Row({ space: 8 }) {
              // 图例圆点用纯布局（borderRadius），不用 Circle.fill（该 API SDK 26 起）
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor($r('app.color.danger'))
              Text(`阻断 ${this.snapshot.stats !== null ? this.snapshot.stats.dns_blocked : 0}`)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
            }
            Row({ space: 8 }) {
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor($r('app.color.safe'))
              Text(`放行 ${this.snapshot.stats !== null ? this.snapshot.stats.dns_forwarded : 0}`)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))

        // TCP/UDP 概览磁贴（子组件 @Prop）
        Row() {
          StatTile({
            label: 'TCP 阻断',
            value: String(this.snapshot.stats !== null ? this.snapshot.stats.tcp_blocked : 0),
            valueColor: $r('app.color.danger')
          })
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          StatTile({
            label: 'TCP 转发',
            value: String(this.snapshot.stats !== null ? this.snapshot.stats.tcp_relayed : 0),
            valueColor: $r('app.color.text_primary')
          })
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          StatTile({
            label: 'UDP 阻断',
            value: String(this.snapshot.stats !== null ? this.snapshot.stats.udp_blocked : 0),
            valueColor: $r('app.color.danger')
          })
        }
        .width('92%')
        .padding({ top: 18, bottom: 18 })
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))

        if (this.actionMsg !== '') {
          Text(this.actionMsg)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width('92%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: 96 }) // 浮起 Tab 栏避让
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
}
