// 内置规则服务（鸿蒙壳）：filesDir/rules/ 下随包分发的种子文件
// starter.txt（拦截）与 protected-allow.txt（放行，$important 保护清单）。
// 规则内容随 HAP rawfile 分发（M4-R1：规则外部可见，不内嵌二进制），
// 首启由 EntryAbility.ensureSeedRules 落盘；本服务只读展示 + 启停写回。
//
// 内置规则仅允许「启停」，不允许增删改：启停复用用户规则同一机制——
// 规则行前加 '! ' 注释前缀（引擎按注释整行丢弃）写回原文件，
// 单一事实源仍是文件本身，引擎与跨端格式零改动。
// 种子分发「已有文件不覆盖」，启停状态因此跨启动/跨升级持久。
//
// 行解析/编码直接复用 UserRulesService 导出的纯函数（同一 AdGuard 行格式）；
// 文件 IO 因路径不同在本服务内自持（临时文件 + rename 原子落盘，同用户规则）。

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RuleEntryBase, UserRuleKind, UserRuleEntry, UserRuleResult,
  parseRuleLine, encodeRuleLine
} from './UserRulesService';

const DOMAIN = 0xD22E0;

/** 随包分发的内置规则文件（filesDir/rules/ 下；数组顺序即页面展示顺序）。 */
export const BUILT_IN_FILES: string[] = ['starter.txt', 'protected-allow.txt'];

/**
 * 内置规则条目：file 指明所属种子文件（启停写回目标），lineIndex 为该文件内行号。
 * 继承 RuleEntryBase（ArkTS 禁结构化类型：形状相同但无继承关系不可互换）。
 */
export interface BuiltInRuleEntry extends RuleEntryBase {
  file: string;
  lineIndex: number;
}

/** 读单个内置规则文件并解析条目；文件缺失/不可读 → 空数组（种子可能被用户移除）。 */
function listFileRules(filesDir: string, file: string): BuiltInRuleEntry[] {
  let text = '';
  try {
    text = fs.readTextSync(filesDir + '/rules/' + file);
  } catch (e) {
    return [];
  }
  const lines = text.split('\n');
  const out: BuiltInRuleEntry[] = [];
  for (let i = 0; i < lines.length; i++) {
    const entry: UserRuleEntry | null = parseRuleLine(lines[i], i);
    if (entry === null) {
      continue; // 注释/空行/未知格式：不展示、不干预，原样留在文件里
    }
    const item: BuiltInRuleEntry = {
      file: file,
      lineIndex: entry.lineIndex,
      domain: entry.domain,
      kind: entry.kind,
      enabled: entry.enabled
    };
    out.push(item);
  }
  return out;
}

/** 读全部内置规则条目（按 BUILT_IN_FILES 顺序拼接）。 */
export function listBuiltInRules(filesDir: string): BuiltInRuleEntry[] {
  const out: BuiltInRuleEntry[] = [];
  for (const file of BUILT_IN_FILES) {
    const items = listFileRules(filesDir, file);
    for (const it of items) {
      out.push(it);
    }
  }
  return out;
}

/** 启停切换：按 lineIndex 原位改写指定内置文件中该行的 '! ' 前缀。 */
export function toggleBuiltInRule(filesDir: string, file: string, lineIndex: number,
  enabled: boolean): UserRuleResult {
  const path = filesDir + '/rules/' + file;
  let lines: string[] = [];
  try {
    lines = fs.readTextSync(path).split('\n');
  } catch (e) {
    return { code: -4, message: '内置规则文件不可读：' + file };
  }
  if (lineIndex < 0 || lineIndex >= lines.length) {
    return { code: -4, message: '规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  const old = parseRuleLine(lines[lineIndex], lineIndex);
  if (old === null) {
    return { code: -4, message: '规则已不存在（规则文件被外部修改），请返回后重进规则页' };
  }
  lines[lineIndex] = encodeRuleLine(old.domain, old.kind, enabled);
  try {
    const tmp = path + '.tmp';
    const f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, lines.join('\n') + '\n');
    fs.closeSync(f);
    fs.renameSync(tmp, path);
    return { code: 0, message: '' };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    hilog.error(DOMAIN, 'Dragnet', '[BuiltInRules] toggle write failed: %{public}s', msg);
    return { code: -1, message: '规则文件写盘失败' };
  }
}
