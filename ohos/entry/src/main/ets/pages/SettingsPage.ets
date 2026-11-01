// 设置页：出站 DNS 上游（预置 Select + 自定义输入）+ 外观说明 + 关于。
// 规范合规：
//   - Select 初始文本必须 .value()（selected 只管菜单高亮——踩坑卡）；
//   - Toast 用 getUIContext().getPromptAction().showToast（全局 promptAction 已废弃）；
//   - 保存前 ip:port 格式校验（内核 netip.ParseAddrPort 只接受该形式，入口先拦）；
//   - 颜色全 $r('app.color.*')。

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readDnsUp, writeDnsUp, DEFAULT_DNS_UP } from '../common/DragnetService';

const DOMAIN = 0xD22E0;

interface DnsPreset {
  label: string;
  value: string;
}

@Component
export struct SettingsPage {
  @State dnsUp: string = DEFAULT_DNS_UP;
  @State dnsInput: string = DEFAULT_DNS_UP;
  @State saveMsg: string = '';
  @State selectedPreset: number = 0;
  private presets: DnsPreset[] = [
    { label: '223.5.5.5:53（阿里）', value: '223.5.5.5:53' },
    { label: '119.29.29.29:53（腾讯）', value: '119.29.29.29:53' },
    { label: '1.1.1.1:53（Cloudflare）', value: '1.1.1.1:53' }
  ];

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.dnsUp = readDnsUp(ctx.filesDir);
    this.dnsInput = this.dnsUp;
    // 预置索引对齐（SelectOption.value 是 ResourceStr，取值用 typeof 收窄——规范）。
    this.selectedPreset = -1;
    for (let i = 0; i < this.presets.length; i++) {
      if (this.presets[i].value === this.dnsUp) {
        this.selectedPreset = i;
        break;
      }
    }
  }

  // Select 预置选中：label helper 禁返回空串（越界钳回占位——规范）。
  private presetLabel(index: number): string {
    if (index >= 0 && index < this.presets.length) {
      return this.presets[index].label;
    }
    return '自定义';
  }

  private onPresetSelect(index: number): void {
    this.selectedPreset = index;
    const preset = this.presets[index];
    this.dnsInput = preset.value;
    this.save();
  }

  private save(): void {
    const value = this.dnsInput.trim();
    if (value === '') {
      this.saveMsg = '不能为空（默认 ' + DEFAULT_DNS_UP + '）';
      return;
    }
    // 内核侧 netip.ParseAddrPort 只接受 ip:port，格式不对会导致内核起不来
    //（仅 hilog 可见），在保存入口先拦住。
    if (!/^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$/.test(value)) {
      this.saveMsg = '格式应为 ip:port（IPv4，如 223.5.5.5:53）';
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      writeDnsUp(ctx.filesDir, value);
      this.dnsUp = value;
      this.saveMsg = '已保存，VPN 扩展下次启动时生效';
      hilog.info(DOMAIN, 'Dragnet', '[UI] dns-up saved: %{public}s', value);
      this.getUIContext().getPromptAction().showToast({ message: '已保存', duration: 1500 });
    } catch (e) {
      this.saveMsg = '保存失败';
      hilog.error(DOMAIN, 'Dragnet', '[UI] dns-up save failed');
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

          Select(this.presets.map((p: DnsPreset): SelectOption => {
            return { value: p.label };
          }))
            .selected(this.selectedPreset)
            .value(this.presetLabel(this.selectedPreset)) // 按钮初始文本必须 value（规范）
            .font({ size: 14 })
            .fontColor($r('app.color.text_primary'))
            .selectedOptionFont({ size: 14 })
            .optionFont({ size: 14 })
            .width('100%')
            .onSelect((index: number) => this.onPresetSelect(index))

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
          Text('罗网 Dragnet · v2.0.0（bundle com.march.dragnet）\nGo 统一内核 + 平台薄壳；域名与连接级广告/跟踪器拦截，免证书，不做 MITM。')
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
      .padding({ bottom: 96 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
}
