import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'rule_source.dart' show joinPath;

/// 内置规则（M5-H+ 对齐，2026-11-11 M6-B）：随包种子 starter.txt /
/// protected-allow.txt 已由首启分发落盘（已有同名不覆盖 → 启停态跨启动持久）。
/// 仅可视 + 启停，无增删改；停用 = '! ' 注释前缀写回种子文件本身
/// （引擎按注释丢弃 → 停用即时生效；重启用去前缀恢复）。
/// 行格式与用户规则一致：拦截 `||domain^` / 放行 `@@||domain^$important`。
const String starterFileName = 'starter.txt';
const String protectedAllowFileName = 'protected-allow.txt';

enum BuiltInKind { block, allow }

/// 种子文件里的一条规则（含停用形态）。
class BuiltInRuleEntry {
  const BuiltInRuleEntry({
    required this.file,
    required this.lineIndex,
    required this.domain,
    required this.kind,
    required this.enabled,
    required this.raw,
  });

  /// 种子文件名（starter.txt / protected-allow.txt）。
  final String file;

  /// 在该文件行数组中的下标（toggle 按下标翻转，注释/空行原样保留）。
  final int lineIndex;
  final String domain;
  final BuiltInKind kind;
  final bool enabled;

  /// 原始行文本（未去空白）。
  final String raw;
}

// ── 纯函数（单测覆盖）──────────────────────────────────────────────────────

const String _allowSuffix = r'^$important';

/// 解析种子文件单行；返回 null = 非规则行（普通注释/空行/其他）。
/// 停用形态 = '! ' + 规则行（对齐鸿蒙 M5-H encodeRuleLine）；普通注释行
///（! 后不跟规则形状）不算停用规则。
BuiltInRuleEntry? parseBuiltInRuleLine(String file, int index, String line) {
  var s = line.trim();
  var enabled = true;
  if (s.startsWith('! ')) {
    enabled = false;
    s = s.substring(2).trim();
  } else if (s.startsWith('!')) {
    return null; // '!' 紧贴内容的普通注释
  }
  if (s.startsWith('@@||') && s.endsWith(_allowSuffix)) {
    final d = s.substring(4, s.length - _allowSuffix.length);
    if (d.isEmpty) return null;
    return BuiltInRuleEntry(
        file: file,
        lineIndex: index,
        domain: d,
        kind: BuiltInKind.allow,
        enabled: enabled,
        raw: line.trim());
  }
  if (s.startsWith('||') && s.endsWith('^') && s.length > 3) {
    final d = s.substring(2, s.length - 1);
    if (d.isEmpty) return null;
    return BuiltInRuleEntry(
        file: file,
        lineIndex: index,
        domain: d,
        kind: BuiltInKind.block,
        enabled: enabled,
        raw: line.trim());
  }
  return null;
}

/// 解析种子文件全文（保留行序；lineIndex 指向原文件行数组）。
List<BuiltInRuleEntry> parseBuiltInRules(String file, String text) {
  final lines = text.split('\n');
  final out = <BuiltInRuleEntry>[];
  for (var i = 0; i < lines.length; i++) {
    final e = parseBuiltInRuleLine(file, i, lines[i]);
    if (e != null) out.add(e);
  }
  return out;
}

/// 翻转指定行的启停：返回新文件文本（其余行原样保留，含注释与空行）；
/// 行下标越界/非规则行返回 null（调用方不写盘）。
String? toggleBuiltInLine(String text, int lineIndex) {
  final lines = text.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return null;
  final l = lines[lineIndex];
  final s = l.trim();
  // 先判定必须是规则形状（启用或 '! ' 停用皆可；普通注释/空行/垃圾行拒绝，
  // 否则 '! 头注释' 会被误剥前缀损坏文件——单测实捕）
  if (parseBuiltInRuleLine('', lineIndex, l) == null) return null;
  final flipped =
      s.startsWith('! ') ? s.substring(2) : '! $s'; // 重启用去前缀 / 停用加前缀
  lines[lineIndex] = flipped;
  return lines.join('\n');
}

// ── 服务 ───────────────────────────────────────────────────────────────────

/// 内置规则文件面（ChangeNotifier）。磁盘读写只在 Android 上执行
/// （测试环境纯内存），异常捕获 + debugPrint，绝不向调用方抛。
class BuiltInRulesService extends ChangeNotifier {
  static final BuiltInRulesService instance = BuiltInRulesService._();

  BuiltInRulesService._();

  List<BuiltInRuleEntry> entries = [];
  String rulesDir = '';
  bool loaded = false;
  bool busy = false;

  bool get _canWrite => Platform.isAndroid;

  String get _starterPath => joinPath(rulesDir, starterFileName);
  String get _protectedPath => joinPath(rulesDir, protectedAllowFileName);

  int get blockCount =>
      entries.where((e) => e.kind == BuiltInKind.block).length;
  int get allowCount =>
      entries.where((e) => e.kind == BuiltInKind.allow).length;
  int get disabledCount => entries.where((e) => !e.enabled).length;

  Future<void> ensureLoaded(String dir) async {
    if (dir.isEmpty) return;
    if (loaded && rulesDir == dir) return;
    rulesDir = dir;
    await _readFromDisk();
  }

  Future<void> _readFromDisk() async {
    final out = <BuiltInRuleEntry>[];
    for (final path in [_starterPath, _protectedPath]) {
      try {
        final f = File(path);
        if (!await f.exists()) continue; // 种子可能被用户移除 → 该文件为空
        final name = path.endsWith(starterFileName)
            ? starterFileName
            : protectedAllowFileName;
        out.addAll(parseBuiltInRules(name, await f.readAsString()));
      } catch (e) {
        debugPrint('内置规则读取失败($path): $e');
      }
    }
    entries = out;
    loaded = true;
    notifyListeners();
  }

  /// 启停一条：翻转写回种子文件本身（tmp + rename 原子落盘）→ 重读 → 通知。
  /// 返回 false = 未写盘（下标失效/非 Android/IO 失败）。
  Future<bool> toggle(BuiltInRuleEntry e) async {
    if (busy || !_canWrite || rulesDir.isEmpty) return false;
    busy = true;
    var ok = false;
    try {
      final path = e.file == starterFileName ? _starterPath : _protectedPath;
      final f = File(path);
      if (!await f.exists()) return false;
      final next = toggleBuiltInLine(await f.readAsString(), e.lineIndex);
      if (next == null) return false;
      final tmp = File('$path.m6b.tmp');
      await tmp.writeAsString(next, flush: true);
      await tmp.rename(path);
      ok = true;
    } catch (err) {
      debugPrint('内置规则启停写盘失败: $err');
    } finally {
      busy = false;
    }
    if (ok) await _readFromDisk();
    return ok;
  }
}
