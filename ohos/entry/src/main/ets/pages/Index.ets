// 罗网 P0-H 最小链路壳 UI：起停按钮 + 状态回显（与 Android MainActivity 对齐）。
// 统计经 dragnet.stats()（若 VPN 扩展与 UI 同进程则返回 JSON，否则空串——
// 权威验证走 hilog，见 ohos/README.md）。

import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { stats, match } from 'libdragnet.so';

const DOMAIN = 0xD22E0;
const TAG = 'Dragnet';

interface MatchResult {
  action: string;
  rule: string;
  list: string;
}

@Entry
@Component
struct Index {
  @State status: string = '未运行';
  private vpnWant: Want = {
    deviceId: '',
    bundleName: 'com.march.cimoc',
    abilityName: 'VpnExtAbility'
  };

  build() {
    Column({ space: 16 }) {
      Text('罗网 · 鸿蒙最小链路')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48 })

      Button('启动拦截')
        .width('70%')
        .fontSize(18)
        .onClick(() => {
          vpnExtension.startVpnExtensionAbility(this.vpnWant).then((): void => {
            this.status = 'VPN 扩展启动成功（首次会弹系统授权对话框）';
            hilog.info(DOMAIN, TAG, 'startVpnExtensionAbility ok');
          }).catch((err: BusinessError): void => {
            this.status = '启动失败: code=' + err.code + ' ' + err.message;
            hilog.error(DOMAIN, TAG, 'startVpnExtensionAbility failed: %{public}s', err.message);
          });
        })

      Button('停止拦截')
        .width('70%')
        .fontSize(18)
        .onClick(() => {
          vpnExtension.stopVpnExtensionAbility(this.vpnWant).then((): void => {
            this.status = 'VPN 扩展已停止';
            hilog.info(DOMAIN, TAG, 'stopVpnExtensionAbility ok');
          }).catch((err: BusinessError): void => {
            this.status = '停止失败: code=' + err.code + ' ' + err.message;
          });
        })

      Button('运行统计')
        .width('70%')
        .fontSize(18)
        .onClick(() => {
          const s: string = stats();
          this.status = s === '' ? '（未运行，或 VPN 扩展在独立进程）' : s;
        })

      Button('匹配自检（doubleclick.net）')
        .width('70%')
        .fontSize(18)
        .onClick(() => {
          const raw: string = match('doubleclick.net');
          if (raw === '') {
            this.status = '（引擎空载：先 push 规则，见 ohos/README.md）';
          } else {
            try {
              const r: MatchResult = JSON.parse(raw) as MatchResult;
              this.status = 'action=' + r.action + ' rule=' + r.rule + ' list=' + r.list;
            } catch (e) {
              this.status = raw;
            }
          }
        })

      Text(this.status)
        .fontSize(14)
        .fontColor('#666666')
        .padding(16)
        .textAlign(TextAlign.Center)
    }
    .height('100%')
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
