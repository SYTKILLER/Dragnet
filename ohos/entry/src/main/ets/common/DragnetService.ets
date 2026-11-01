// 罗网 UI 公共服务层：NAPI 包装 + 跨进程状态桥 + 设置读写。
//
// 统计桥（核心）：VPN 扩展跑在独立进程（com.march.dragnet:vpn），UI 进程
// stats() 恒返回 ""。桥接方案 = 状态文件轮询：
//   VpnExtAbility 每 2s 把 {state, ts, stats} 写入 filesDir/state/stats.json；
//   UI 侧 readVpnSnapshot() 读该文件，ts 超过 STATE_STALE_SEC 判定"未运行"
//   （VPN 扩展进程被系统杀死、未走 onDestroy 时也能正确降级）。

import { fileIo as fs } from '@kit.CoreFileKit';
import { loadRules, ruleInfo, match } from 'libdragnet.so';

/** 内核运行统计（cmd/dragnetohos stats() JSON 字段）。 */
export interface RunStats {
  uptime_sec: number;
  dns_blocked: number;
  dns_forwarded: number;
  tcp_blocked: number;
  tcp_relayed: number;
  udp_blocked: number;
  udp_relayed: number;
  cache: number;
}

/** 已加载规则规模（cmd/dragnetohos ruleInfo() JSON 字段）。 */
export interface RuleInfo {
  lists: number;
  rule_lines: number;
  rule_bytes: number;
}

/** 域名判定结果（cmd/dragnetohos match() JSON 字段）。 */
export interface MatchResult {
  action: string; // BLOCK | ALLOW | NOMATCH
  rule: string;
  list: string;
}

/** filesDir/state/stats.json 的落盘结构（VpnExtAbility 写、UI 读）。 */
export interface VpnStateFile {
  state: string; // running | stopped | error
  ts: number; // 写盘时刻（epoch 秒）
  stats: RunStats | null;
  errRc?: number; // state=error 时的内核 startVpn 返回码（负数）
  errMsg?: string; // state=error 时的底层错误文本（内核 lastError()）
}

/** UI 侧视角的 VPN 运行快照。 */
export interface VpnSnapshot {
  running: boolean;
  stats: RunStats | null;
  lastTs: number; // VPN 侧最近写盘时间（秒）；0 = 从未写过
  errorRc: number; // 非 0 = VPN 侧上报的内核启动失败返回码（终态，直到下次写盘）
  errMsg: string; // 底层错误文本（"" = 无）
}

// 超过该秒数未见 VPN 侧刷新即判未运行（写盘周期 2s，留 5 倍余量）。
const STATE_STALE_SEC = 10;

/** 读跨进程状态文件并判活；文件缺失/损坏一律按未运行处理。 */
export function readVpnSnapshot(filesDir: string): VpnSnapshot {
  let snap: VpnSnapshot = { running: false, stats: null, lastTs: 0, errorRc: 0, errMsg: '' };
  try {
    const text: string = fs.readTextSync(filesDir + '/state/stats.json');
    const sf: VpnStateFile = JSON.parse(text) as VpnStateFile;
    snap.lastTs = sf.ts;
    if (sf.state === 'running' && sf.stats !== null) {
      const now = Math.floor(Date.now() / 1000);
      if (now - sf.ts <= STATE_STALE_SEC) {
        snap.running = true;
        snap.stats = sf.stats;
      }
    } else if (sf.state === 'error' && typeof sf.errRc === 'number') {
      // 内核启动失败终态：UI 显示明确错误而非笼统"未运行"
      snap.errorRc = sf.errRc;
      snap.errMsg = sf.errMsg ?? '';
    }
  } catch (e) {
    // 首次安装（VPN 未起过）或文件损坏 → 未运行
  }
  return snap;
}

/** UI 进程加载规则目录（自检/规则页用；与 VPN 进程各自独立实例，无副作用）。 */
export function loadRulesDir(filesDir: string): number {
  return loadRules(filesDir + '/rules');
}

/** 规则规模信息；引擎空载返回 null。 */
export function readRuleInfo(): RuleInfo | null {
  try {
    const raw: string = ruleInfo();
    if (raw === '') {
      return null;
    }
    return JSON.parse(raw) as RuleInfo;
  } catch (e) {
    return null;
  }
}

/** 域名判定；引擎空载返回 null。 */
export function matchDomain(domain: string): MatchResult | null {
  const raw: string = match(domain);
  if (raw === '') {
    return null;
  }
  try {
    return JSON.parse(raw) as MatchResult;
  } catch (e) {
    return null;
  }
}

// ---- 设置：出站 DNS 上游（VPN 扩展启动时读取，落 filesDir/config）----

export const DEFAULT_DNS_UP = '223.5.5.5:53';

export function readDnsUp(filesDir: string): string {
  try {
    const text: string = fs.readTextSync(filesDir + '/config/dns-up.txt').trim();
    return text === '' ? DEFAULT_DNS_UP : text;
  } catch (e) {
    return DEFAULT_DNS_UP;
  }
}

export function writeDnsUp(filesDir: string, value: string): void {
  const dir = filesDir + '/config';
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  const file = fs.openSync(dir + '/dns-up.txt',
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, value);
  fs.closeSync(file);
}

/** 列出规则目录下的 .txt 文件名（不含路径）；目录不存在返回空数组。 */
export function listRuleFiles(filesDir: string): string[] {
  try {
    const names: string[] = fs.listFileSync(filesDir + '/rules');
    const out: string[] = [];
    for (const n of names) {
      if (n.endsWith('.txt')) {
        out.push(n);
      }
    }
    return out;
  } catch (e) {
    return [];
  }
}

/** 规则文件字节数；不可读返回 -1。 */
export function ruleFileSize(filesDir: string, name: string): number {
  try {
    return fs.statSync(filesDir + '/rules/' + name).size;
  } catch (e) {
    return -1;
  }
}

// ---- 文案辅助 ----

export function formatUptime(sec: number): string {
  const s = Math.floor(sec % 60);
  const m = Math.floor((sec / 60) % 60);
  const h = Math.floor(sec / 3600);
  if (h > 0) {
    return `${h} 时 ${m} 分 ${s} 秒`;
  }
  if (m > 0) {
    return `${m} 分 ${s} 秒`;
  }
  return `${s} 秒`;
}

export function formatBytes(n: number): string {
  if (n < 1024) {
    return `${n} B`;
  }
  if (n < 1024 * 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** loadRules 返回码转可读文案（0/-1/-2/-3，见 libdragnet.d.ts）。 */
export function loadRulesErrorText(rc: number): string {
  if (rc === 0) {
    return '规则加载成功';
  }
  if (rc === -1) {
    return '加载失败：参数为空';
  }
  if (rc === -2) {
    return '加载失败：规则目录不可读';
  }
  return '加载失败：规则文件解析错误（保留原引擎，空载 fail-open）';
}

/** 内核 startVpn 返回码转可读文案（与 cmd/dragnetohos/main.go 对齐）。 */
export function startVpnErrorText(rc: number): string {
  if (rc === -10) {
    return '内核已在运行';
  }
  if (rc === -11) {
    return 'DNS 上游格式错误（设置页检查）';
  }
  if (rc === -12) {
    return 'TUN 文件描述符无效';
  }
  if (rc === -14) {
    return 'TUN 设备创建失败';
  }
  if (rc === -15) {
    return '网络栈构建失败';
  }
  if (rc === -16) {
    return 'TUN 设备启动失败';
  }
  if (rc === -17) {
    return '网络栈启动失败';
  }
  if (rc === -99) {
    return '内核异常（panic）';
  }
  return `内核启动失败（错误码 ${rc}）`;
}
