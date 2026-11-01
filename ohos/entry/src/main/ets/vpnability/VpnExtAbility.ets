// 罗网 P0-H 最小链路：三方 VPN 扩展（HarmonyOS VpnExtensionAbility）。
// 职责与 Android 薄壳（DragnetVpnService）完全对齐：
//   create 拿 tun fd → 注册 protect 回调 → 起停内核；拦截逻辑全部在
//   libdragnet.so（Go 内核，与 Windows/Android 共用 internal/tunstack）。
//
// 出站防回环：内核拨号前回调 (id, fd) → 本类调 VpnConnection.protect(fd)
// → 完成后 setProtected(id) 回握内核（超时 5s，见 cmd/dragnetohos/main.go）。
//
// 跨进程统计桥：内核上线后每 2s 调 stats() 把 {state, ts, stats} 写入
// filesDir/state/stats.json；UI 进程轮询读该文件（UI 进程 stats() 恒空）。
// 进程被系统杀死未走 onDestroy 时，UI 侧按 ts 过期判"未运行"。

import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { startVpn, stopVpn, setProtected, loadRules, stats, lastError } from 'libdragnet.so';
import { readDnsUp, RunStats, VpnStateFile } from '../common/DragnetService';

const DOMAIN = 0xD22E0;
const TAG = 'Dragnet';

// 与内核 cmd/dragnetohos/main.go 保持一致。
const TUN_ADDR = '10.111.222.1';
const TUN_DNS = '10.111.222.3';
const DNS_UP_DEFAULT = '223.5.5.5:53'; // 出站上游 DNS 缺省（protect 绕过 TUN；可在设置页改）
const MTU = 1500;
const STATS_DUMP_INTERVAL_MS = 2000;

export default class VpnExtAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private setupStarted = false;
  private statsTimer: number = -1;

  onCreate(want: Want): void {
    this.setup();
  }

  // PoC 直启路径：模拟器镜像缺 com.huawei.hmos.vpndialog（首次信任授权对话框
  // 系统应用），startVpnExtensionAbility 的授权流程走不通；调试/验证可经
  //   hdc shell aa start -a VpnExtAbility -b com.march.dragnet
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
    console.info(`[VPN] loadRules(${filesDir}/rules) = ${rulesRc}`);

    // 出站 DNS 上游：设置页可改（filesDir/config/dns-up.txt），缺省回退。
    const dnsUp: string = readDnsUp(filesDir);

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
      console.info(`[VPN] VpnConnection.create -> tunFd=${tunFd}`);
      startVpn(tunFd, dnsUp, MTU, (id: number, fd: number): void => {
        this.conn?.protect(fd).then((): void => {
          console.info(`[VPN] protect fd=${fd} ok`);
          setProtected(id);
        }).catch((err: BusinessError): void => {
          // 失败也回握：让内核放弃该次拨号（防回环），而非干等 5s 超时。
          console.info(`[VPN] protect fd=${fd} failed: ${err.message}`);
          setProtected(id);
        });
      }).then((rc: number) => {
        console.info(`[VPN] startVpn = ${rc}`);
        if (rc === 0) {
          this.startStatsWriter();
        } else {
          // 内核启动失败：取底层错误文本（lastError，见 main.go）写 console
          // 与 error 终态（UI 显示明确原因而非笼统"未运行"）
          const why: string = lastError();
          console.info(`[VPN] startVpn failed why: ${why}`);
          this.writeStateFile('error', null, rc, why);
        }
      }).catch((err: BusinessError) => {
        console.info(`[VPN] startVpn rejected: ${err.message}`);
        this.writeStateFile('error', null, -98, err.message);
      });
    }).catch((err: BusinessError) => {
      console.info(`[VPN] VpnConnection.create failed: ${err.message}`);
    });
  }

  // startStatsWriter 周期把运行统计落盘到 filesDir/state/stats.json，
  // 供 UI 进程轮询（跨进程统计桥，见 common/DragnetService.ets）。
  private startStatsWriter(): void {
    const stateDir = this.context.filesDir + '/state';
    try {
      if (!fs.accessSync(stateDir)) {
        fs.mkdirSync(stateDir, true);
      }
    } catch (e) {
      console.info('[VPN] state dir create failed');
      return;
    }
    this.statsTimer = setInterval((): void => {
      try {
        const raw: string = stats();
        const st: RunStats | null = raw === '' ? null : JSON.parse(raw) as RunStats;
        this.writeStateFile('running', st, 0);
      } catch (e) {
        console.info('[VPN] stats dump failed');
      }
    }, STATS_DUMP_INTERVAL_MS);
    // 立即写一次，UI 无需等第一个周期
    this.writeStateFile('running', null, 0);
  }

  // writeStateFile 统一状态落盘（running 周期/立即写、stopped/error 终态）。
  private writeStateFile(state: string, st: RunStats | null, errRc: number,
    errMsg: string = '', stateDir: string = this.context.filesDir + '/state'): void {
    try {
      if (!fs.accessSync(stateDir)) {
        fs.mkdirSync(stateDir, true);
      }
      const sf: VpnStateFile = { state: state, ts: Math.floor(Date.now() / 1000), stats: st };
      if (state === 'error') {
        sf.errRc = errRc;
        sf.errMsg = errMsg;
      }
      const file = fs.openSync(stateDir + '/stats.json',
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(sf));
      fs.closeSync(file);
    } catch (e) {
      console.info(`[VPN] state dump (${state}) failed`);
    }
  }

  // stopStatsWriter 停表并落"已停止"终态（UI 立即显示未运行）。
  private stopStatsWriter(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    this.writeStateFile('stopped', null, 0);
  }

  onDestroy(): void {
    console.info('[VPN] VpnExtAbility onDestroy');
    this.stopStatsWriter();
    const rc: number = stopVpn();
    console.info(`[VPN] stopVpn = ${rc}`);
    this.conn?.destroy().then((): void => {
      console.info('[VPN] VpnConnection.destroy ok');
    }).catch((err: BusinessError): void => {
      console.info(`[VPN] VpnConnection.destroy failed: ${err.message}`);
    });
    this.conn = null;
  }
}
