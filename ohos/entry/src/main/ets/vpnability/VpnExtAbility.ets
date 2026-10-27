// 罗网 P0-H 最小链路：三方 VPN 扩展（HarmonyOS VpnExtensionAbility）。
// 职责与 Android 薄壳（DragnetVpnService）完全对齐：
//   create 拿 tun fd → 注册 protect 回调 → 起停内核；拦截逻辑全部在
//   libdragnet.so（Go 内核，与 Windows/Android 共用 internal/tunstack）。
//
// 出站防回环：内核拨号前回调 (id, fd) → 本类调 VpnConnection.protect(fd)
// → 完成后 setProtected(id) 回握内核（超时 5s，见 cmd/dragnetohos/main.go）。

import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { startVpn, stopVpn, setProtected, loadRules } from 'libdragnet.so';

const DOMAIN = 0xD22E0;
const TAG = 'Dragnet';

// 与内核 cmd/dragnetohos/main.go 保持一致。
const TUN_ADDR = '10.111.222.1';
const TUN_DNS = '10.111.222.3';
const DNS_UP = '223.5.5.5:53'; // 出站上游 DNS（protect 绕过 TUN）
const MTU = 1500;

export default class VpnExtAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private setupStarted = false;

  onCreate(want: Want): void {
    this.setup();
  }

  // PoC 直启路径：模拟器镜像缺 com.huawei.hmos.vpndialog（首次信任授权对话框
  // 系统应用），startVpnExtensionAbility 的授权流程走不通；调试/验证可经
  //   hdc shell aa start -a VpnExtAbility -b com.march.cimoc
  // 直启（框架按 ServiceExtension 生命周期派发 onRequest）。setup 幂等。
  onRequest(want: Want, startId: number): void {
    this.setup();
  }

  private setup(): void {
    if (this.setupStarted) {
      return;
    }
    this.setupStarted = true;
    const filesDir = this.context.filesDir;
    // M4-R1 规则可见性：规则仅从 filesDir/rules 外部加载，无内嵌种子；
    // 未加载时空载 fail-open（内核侧 WARN）。
    const rulesRc: number = loadRules(filesDir + '/rules');
    console.info(`[Dragnet] loadRules(${filesDir}/rules) = ${rulesRc}`);

    this.conn = vpnExtension.createVpnConnection(this.context);
    const addr: connection.LinkAddress = {
      address: { address: TUN_ADDR, family: 1 },
      prefixLength: 24
    };
    const defaultRoute: connection.RouteInfo = {
      interface: '',
      destination: {
        address: { address: '0.0.0.0', family: 1 },
        prefixLength: 0
      },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: true
    };
    const config: vpnExtension.VpnConfig = {
      addresses: [addr],
      routes: [defaultRoute],
      dnsAddresses: [TUN_DNS],
      mtu: MTU
    };

    this.conn.create(config).then((tunFd: number) => {
      console.info(`[Dragnet] VpnConnection.create -> tunFd=${tunFd}`);
      startVpn(tunFd, DNS_UP, MTU, (id: number, fd: number): void => {
        this.conn?.protect(fd).then((): void => {
          console.info(`[Dragnet] protect fd=${fd} ok`);
          setProtected(id);
        }).catch((err: BusinessError): void => {
          // 失败也回握：让内核放弃该次拨号（防回环），而非干等 5s 超时。
          console.info(`[Dragnet] protect fd=${fd} failed: ${err.message}`);
          setProtected(id);
        });
      }).then((rc: number) => {
        console.info(`[Dragnet] startVpn = ${rc}`);
      }).catch((err: BusinessError) => {
        console.info(`[Dragnet] startVpn rejected: ${err.message}`);
      });
    }).catch((err: BusinessError) => {
      console.info(`[Dragnet] VpnConnection.create failed: ${err.message}`);
    });
  }

  onDestroy(): void {
    console.info('[Dragnet] VpnExtAbility onDestroy');
    const rc: number = stopVpn();
    console.info(`[Dragnet] stopVpn = ${rc}`);
    this.conn?.destroy().then((): void => {
      console.info('[Dragnet] VpnConnection.destroy ok');
    }).catch((err: BusinessError): void => {
      console.info(`[Dragnet] VpnConnection.destroy failed: ${err.message}`);
    });
    this.conn = null;
  }
}
