// 用户规则服务（鸿蒙壳）：filesDir/rules/zzz-user-rules.txt，
// 与 Android 壳 M5-A 同名同格式：拦截 `||domain^` / 放行 `@@||domain^$important`
// （$important 例外优先于订阅阻断，对齐 Windows 端 zzz-user-allow.txt 惯例）。
//
// 停用条目 = 规则行前加 '! ' 前缀：内核按注释整行丢弃（引擎不含停用规则），
// 本页解析回"已停用"条目。单文件单一事实源，内核按 *.txt 全量加载，无需注册。
// 非规则行（空行 / 纯注释 / 未知格式）在增删改写回时原样保留，不丢失。
//
// 全部操作采用「现读-改-写」：不持有内存态，避免与外部编辑（设置页说明鼓励
// 用户自行编辑规则文件）产生陈旧覆盖。写盘为临时文件 + rename 原子落盘。

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xD22E0;

export const USER_RULES_FILE = 'zzz-user-rules.txt';

const DISABLED_PREFIX = '! ';
const ALLOW_SUFFIX = '^$important';

export enum UserRuleKind {
  BLOCK = 'block',
  ALLOW = 'allow'
}

/** zzz-user-rules.txt 里的一条用户规则（lineIndex 指向文件行，供原位改写）。 */
export interface UserRuleEntry {
  lineIndex: number;
  domain: string;
  kind: UserRuleKind;
  enabled: boolean;
}

/** 增删改结果（resolve 结果对象模式，不用裸异常/裸 reject）。 */
export interface UserRuleResult {
  code: number; // 0 成功；-1 写盘失败；-2 域名不合法；-3 重复规则；-4 条目已不存在
  message: string; // 失败原因；成功为 ''
}

export function userRulesPath(filesDir: string): string {
  return filesDir + '/rules/' + USER_RULES_FILE;
}

/** 域名合法性（对齐 flutter_app isValidDomain：[a-z0-9.-]、≤253、至少一个点、无空标签）。 */
export function isValidUserDomain(domain: string): boolean {
  if (domain === '' || domain.length > 253) {
    return false;
  }
  if (!domain.includes('.')) {
    return false;
  }
  if (domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) {
    return false;
  }
  return /^[a-z0-9.-]+$/.test(domain);
}

/** 规则行编码：启用=本体；停用='! '+本体。 */
export function encodeRuleLine(domain: string, kind: UserRuleKind, enabled: boolean): string {
  const body: string = kind === UserRuleKind.ALLOW
    ? '@@||' + domain + ALLOW_SUFFIX
    : '||' + domain + '^';
  return enabled ? body : DISABLED_PREFIX + body;
}

/** 解析单行：规则行返回条目；空行/注释/未知格式返回 null（调用方原样保留）。 */
export function parseRuleLine(line: string, lineIndex: number): UserRuleEntry | null {
  let body = line.trim();
  if (body === '') {
    return null;
  }
  let enabled = true;
  if (body.startsWith(DISABLED_PREFIX)) {
    enabled = false;
    body = body.substring(DISABLED_PREFIX.length).trim();
  } else if (body.startsWith('!') || body.startsWith('#')) {
    return null; // 纯注释行
  }
  if (body.startsWith('@@||') && body.endsWith(ALLOW_SUFFIX)) {
    const d: string = body.substring(4, body.length - ALLOW_SUFFIX.length);
    const entry: UserRuleEntry = { lineIndex: lineIndex, domain: d, kind: UserRuleKind.ALLOW, enabled: enabled };
    return entry;
  }
  if (body.startsWith('||') && body.endsWith('^')) {
    const d: string = body.substring(2, body.length - 1);
    const entry: UserRuleEntry = { lineIndex: lineIndex, domain: d, kind: UserRuleKind.BLOCK, enabled: enabled };
    return entry;
  }
  return null;
}

/** 读全部条目（文件缺失/不可读 → 空数组）。 */
export function listUserRules(filesDir: string): UserRuleEntry[] {
  const lines: string[] = readRawLines(filesDir);
  const out: UserRuleEntry[] = [];
  for (let i = 0; i < lines.length; i++) {
    const entry = parseRuleLine(lines[i], i);
    if (entry !== null) {
      out.push(entry);
    }
  }
  return out;
}

// ---- 内部：文件读写 ----

/** 读原始行数组（末尾空行剔除，写回时统一补单换行）。 */
function readRawLines(filesDir: string): string[] {
  let text = '';
  try {
    text = fs.readTextSync(userRulesPath(filesDir));
  } catch (e) {
    return []; // 首次使用：文件尚不存在
  }
  const lines = text.split('\n');
  while (lines.length > 0 && lines[lines.length - 1].trim() === '') {
    lines.pop();
  }
  return lines;
}

/** 写回全部行（临时文件 + rename 原子落盘；rename 同目录替换目标）。 */
function writeRuleLines(filesDir: string, lines: string[]): number {
  const path = userRulesPath(filesDir);
  try {
    const tmp = path + '.tmp';
    const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const body = lines.length === 0 ? '' : lines.join('\n') + '\n';
    fs.writeSync(file.fd, body);
    fs.closeSync(file);
    fs.renameSync(tmp, path);
    return 0;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    hilog.error(DOMAIN, 'Dragnet', '[UserRules] write failed: %{public}s', msg);
    return -1;
  }
}

/** 同域同类型重复检测（任意启用状态均算重复；skipLine<0 不跳过）。返回重复行号或 -1。 */
function dupLine(lines: string[], skipLine: number, domain: string, kind: UserRuleKind): number {
  for (let i = 0; i < lines.length; i++) {
    if (i === skipLine) {
      continue;
    }
    const e = parseRuleLine(lines[i], i);
    if (e !== null && e.domain === domain && e.kind === kind) {
      return i;
    }
  }
  return -1;
}

// ---- 增删改启停（全部现读-改-写）----

/** 新增规则（默认启用，追加到文件末尾）。入参域名会 trim+小写。 */
export function addUserRule(filesDir: string, domain: string, kind: UserRuleKind): UserRuleResult {
  const d = domain.trim().toLowerCase();
  if (!isValidUserDomain(d)) {
    return { code: -2, message: '域名不合法：仅小写字母/数字/点/连字符，且须至少含一个点' };
  }
  const lines = readRawLines(filesDir);
  if (dupLine(lines, -1, d, kind) >= 0) {
    return { code: -3, message: '已存在同域同类型规则（停用状态也算重复，请直接启用它）' };
  }
  lines.push(encodeRuleLine(d, kind, true));
  const rc = writeRuleLines(filesDir, lines);
  return rc === 0 ? { code: 0, message: '' } : { code: rc, message: '规则文件写盘失败' };
}

/** 编辑规则（按 lineIndex 原位覆写，保留原启用状态）。 */
export function updateUserRule(filesDir: string, lineIndex: number,
  domain: string, kind: UserRuleKind): UserRuleResult {
  const d = domain.trim().toLowerCase();
  if (!isValidUserDomain(d)) {
    return { code: -2, message: '域名不合法：仅小写字母/数字/点/连字符，且须至少含一个点' };
  }
  const lines = readRawLines(filesDir);
  if (lineIndex < 0 || lineIndex >= lines.length || parseRuleLine(lines[lineIndex], lineIndex) === null) {
    return { code: -4, message: '原规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  if (dupLine(lines, lineIndex, d, kind) >= 0) {
    return { code: -3, message: '已存在同域同类型规则（停用状态也算重复，请直接启用它）' };
  }
  const old = parseRuleLine(lines[lineIndex], lineIndex);
  // old 非 null（上方已判），收窄以满足类型检查
  lines[lineIndex] = encodeRuleLine(d, kind, old !== null ? old.enabled : true);
  const rc = writeRuleLines(filesDir, lines);
  return rc === 0 ? { code: 0, message: '' } : { code: rc, message: '规则文件写盘失败' };
}

/** 删除规则（按 lineIndex 整行移除）。 */
export function deleteUserRule(filesDir: string, lineIndex: number): UserRuleResult {
  const lines = readRawLines(filesDir);
  if (lineIndex < 0 || lineIndex >= lines.length || parseRuleLine(lines[lineIndex], lineIndex) === null) {
    return { code: -4, message: '规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  lines.splice(lineIndex, 1);
  const rc = writeRuleLines(filesDir, lines);
  return rc === 0 ? { code: 0, message: '' } : { code: rc, message: '规则文件写盘失败' };
}

/** 启停切换（按 lineIndex 原位改写启用前缀）。 */
export function toggleUserRule(filesDir: string, lineIndex: number, enabled: boolean): UserRuleResult {
  const lines = readRawLines(filesDir);
  if (lineIndex < 0 || lineIndex >= lines.length) {
    return { code: -4, message: '规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  const old = parseRuleLine(lines[lineIndex], lineIndex);
  if (old === null) {
    return { code: -4, message: '规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  lines[lineIndex] = encodeRuleLine(old.domain, old.kind, enabled);
  const rc = writeRuleLines(filesDir, lines);
  return rc === 0 ? { code: 0, message: '' } : { code: rc, message: '规则文件写盘失败' };
}
