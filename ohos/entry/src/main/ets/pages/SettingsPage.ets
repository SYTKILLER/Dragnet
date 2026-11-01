// 设置页：出站 DNS 上游（写 filesDir/config/dns-up.txt，VPN 扩展下次启动生效）
// + 外观说明 + 关于。

import { common } from '@kit.AbilityKit';
import { readDnsUp, writeDnsUp, DEFAULT_DNS_UP } from '../common/DragnetService';

@Component
export struct SettingsPage {
  @State dnsUp: string = DEFAULT_DNS_UP;
  @State dnsInput: string = DEFAULT_DNS_UP;
  @State saveMsg: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.dnsUp = readDnsUp(ctx.filesDir);
    this.dnsInput = this.dnsUp;
  }

  private save(): void {
    const value = this.dnsInput.trim();
    if (value === '') {
      this.saveMsg = '不能为空（留空恢复默认请直接填 ' + DEFAULT_DNS_UP + '）';
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      writeDnsUp(ctx.filesDir, value);
      this.dnsUp = value;
      this.saveMsg = '已保存，VPN 扩展下次启动时生效';
    } catch (e) {
      this.saveMsg = '保存失败';
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('设置')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('92%')
          .margin({ top: 16 })

        // DNS 上游
        Column({ space: 10 }) {
          Text('出站 DNS 上游')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('内核把 TUN 内的 DNS 查询转发到该地址（格式 ip:port）。该出站流量经 protect 绕过 TUN，不参与拦截。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.dnsInput, placeholder: DEFAULT_DNS_UP })
              .layoutWeight(1)
              .height(42)
              .fontSize(14)
              .onChange((value: string) => {
                this.dnsInput = value;
              })
            Button('保存')
              .height(42)
              .fontSize(15)
              .backgroundColor($r('app.color.primary'))
              .onClick(() => this.save())
          }
          .width('100%')
          Text(`当前生效值：${this.dnsUp === '' ? DEFAULT_DNS_UP : this.dnsUp}（默认 ${DEFAULT_DNS_UP}）`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          if (this.saveMsg !== '') {
            Text(this.saveMsg)
              .fontSize(12)
              .fontColor($r('app.color.warn'))
              .width('100%')
          }
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))

        // 外观
        Column({ space: 8 }) {
          Text('外观')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('深浅色跟随系统（COLOR_MODE_NOT_SET）。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))

        // 关于
        Column({ space: 8 }) {
          Text('关于罗网')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('罗网 Dragnet · v1.0.0（bundle com.march.dragnet）\nGo 统一内核 + 平台薄壳；域名与连接级广告/跟踪器拦截，免证书，不做 MITM。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text('规则可见性（M4-R1）：所有规则均为分发包内外部文件（filesDir/rules），不内嵌进二进制；规则目录缺失时空载运行（fail-open）。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text('种子规则 starter.txt 与保护清单 protected-allow.txt 随包分发；已有文件不被覆盖，可自行编辑。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
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
