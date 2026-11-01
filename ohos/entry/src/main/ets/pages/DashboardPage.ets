// 首页仪表盘：VPN 运行状态（轮询跨进程状态文件）+ 拦截开关 + 拦截概览卡。
// 统计数据来自 filesDir/state/stats.json（VpnExtAbility 每 2s 落盘），
// 不直接调 stats()——UI 进程与 VPN 扩展不同进程，stats() 恒为空。

import { vpnExtension } from '@kit.NetworkKit';
import { Want, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readVpnSnapshot, formatUptime, VpnSnapshot } from '../common/DragnetService';

const DOMAIN = 0xD22E0;
const TAG = 'Dragnet';

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
    const ctx = getContext(this) as common.UIAbilityContext;
    this.snapshot = readVpnSnapshot(ctx.filesDir);
  }

  private startBlock(): void {
    // 即时反馈：startVpnExtensionAbility 的 Promise 在授权对话框缺失/等待期间
    // 可能长时间不落定（模拟器实测 netmanager 每 10s 重试 vpndialog），
    // 若只依赖 then/catch 用户会以为点击无效。
    this.actionMsg = '正在启动…（首次会弹系统授权对话框）';
    vpnExtension.startVpnExtensionAbility(this.vpnWant).then((): void => {
      this.actionMsg = 'VPN 扩展启动成功（首次会弹系统授权对话框）';
      hilog.info(DOMAIN, TAG, 'startVpnExtensionAbility ok');
    }).catch((err: BusinessError): void => {
      this.actionMsg = `启动失败: code=${err.code} ${err.message}`;
      hilog.error(DOMAIN, TAG, 'startVpnExtensionAbility failed: %{public}s', err.message);
    });
  }

  private stopBlock(): void {
    this.actionMsg = '正在停止…';
    vpnExtension.stopVpnExtensionAbility(this.vpnWant).then((): void => {
      this.actionMsg = 'VPN 扩展已停止';
      hilog.info(DOMAIN, TAG, 'stopVpnExtensionAbility ok');
    }).catch((err: BusinessError): void => {
      this.actionMsg = `停止失败: code=${err.code} ${err.message}`;
      hilog.error(DOMAIN, TAG, 'stopVpnExtensionAbility failed: %{public}s', err.message);
    });
  }

  @Builder
  statTile(label: string, value: string, valueColor: ResourceColor) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(valueColor)
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
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

        // 状态主卡
        Column({ space: 12 }) {
          Text('🛡')
            .fontSize(56)
          // 状态 pill
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
        .shadow({ radius: 12, color: '#14000000', offsetY: 2 })

        // 开关
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

        // 拦截概览（未运行时归零展示）
        Row() {
          this.statTile('DNS 阻断', String(this.snapshot.stats !== null ? this.snapshot.stats.dns_blocked : 0),
            $r('app.color.danger'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.statTile('TCP 阻断', String(this.snapshot.stats !== null ? this.snapshot.stats.tcp_blocked : 0),
            $r('app.color.danger'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.statTile('DNS 放行', String(this.snapshot.stats !== null ? this.snapshot.stats.dns_forwarded : 0),
            $r('app.color.safe'))
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
      .padding({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
}
