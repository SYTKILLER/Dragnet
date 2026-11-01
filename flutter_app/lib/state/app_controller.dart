import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 内核运行统计（cmd/dragnetvpn nativeStats JSON 字段）。
class KernelStats {
  const KernelStats({
    required this.uptimeSec,
    required this.dnsBlocked,
    required this.dnsForwarded,
    required this.tcpBlocked,
    required this.tcpRelayed,
    required this.udpBlocked,
    required this.udpRelayed,
    required this.cache,
  });

  final int uptimeSec;
  final int dnsBlocked;
  final int dnsForwarded;
  final int tcpBlocked;
  final int tcpRelayed;
  final int udpBlocked;
  final int udpRelayed;
  final int cache;

  static KernelStats? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return KernelStats(
        uptimeSec: m['uptime_sec'] as int? ?? 0,
        dnsBlocked: m['dns_blocked'] as int? ?? 0,
        dnsForwarded: m['dns_forwarded'] as int? ?? 0,
        tcpBlocked: m['tcp_blocked'] as int? ?? 0,
        tcpRelayed: m['tcp_relayed'] as int? ?? 0,
        udpBlocked: m['udp_blocked'] as int? ?? 0,
        udpRelayed: m['udp_relayed'] as int? ?? 0,
        cache: m['cache'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 已加载规则规模（nativeRuleInfo JSON 字段）。
class RuleInfo {
  const RuleInfo({
    required this.lists,
    required this.ruleLines,
    required this.ruleBytes,
  });

  final int lists;
  final int ruleLines;
  final int ruleBytes;

  static RuleInfo? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return RuleInfo(
        lists: m['lists'] as int? ?? 0,
        ruleLines: m['rule_lines'] as int? ?? 0,
        ruleBytes: m['rule_bytes'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 匹配自检结果（nativeMatch JSON 字段；action ∈ BLOCK/ALLOW/NOMATCH）。
class MatchResult {
  const MatchResult({
    required this.action,
    required this.rule,
    required this.list,
  });

  final String action;
  final String rule;
  final String list;

  static MatchResult? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return MatchResult(
        action: m['action'] as String? ?? 'NOMATCH',
        rule: m['rule'] as String? ?? '',
        list: m['list'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 原生桥 + 全局状态。内核运行在同进程 VpnService（与 PoC 壳一致），
/// "运行中"判据 = nativeStats() 非 null（对齐鸿蒙端的轮询口径，2s 周期）。
class AppController extends ChangeNotifier {
  static const _channel = MethodChannel('dragnet/native');

  static final AppController instance = AppController._();

  AppController._();

  KernelStats? stats;
  bool running = false;
  bool starting = false; // startBlock 已发出、等内核上线
  String? startError; // 最近一次启动失败原因
  RuleInfo? ruleInfo;
  String rulesDir = '';

  Timer? _pollTimer;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('dragnet/native $method 失败: ${e.message}');
      rethrow;
    } on MissingPluginException {
      debugPrint('dragnet/native $method: 无原生实现（测试环境）');
      rethrow;
    }
  }

  /// 启动拦截：授权（如需）→ startService → 轮询等内核上线（≤6s）。
  /// 返回 true=已在运行；false=失败（startError 已置）。
  Future<bool> startBlock() async {
    if (running || starting) return running;
    starting = true;
    startError = null;
    notifyListeners();
    try {
      final ok = await _invoke<bool>('startBlock') ?? false;
      if (!ok) {
        starting = false;
        startError = 'VPN 授权被拒绝';
        notifyListeners();
        return false;
      }
      // 轮询 nativeStats 非 null 即内核上线
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await refreshStats(quiet: true);
        if (running) {
          starting = false;
          startError = null;
          notifyListeners();
          unawaited(refreshRuleInfo()); // 规则在 startVpn 时装载
          return true;
        }
      }
      starting = false;
      startError = '内核未在 6s 内上线（logcat -s Dragnet 查看详情）';
      notifyListeners();
      return false;
    } on PlatformException {
      starting = false;
      startError = '原生桥调用失败';
      notifyListeners();
      return false;
    }
  }

  /// 停止拦截：startService(ACTION_STOP)，轮询确认下线（≤3s）。
  Future<void> stopBlock() async {
    startError = null;
    try {
      await _invoke<bool>('stopBlock');
    } on PlatformException {
      // 忽略：轮询会给出真实状态
    }
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refreshStats(quiet: true);
      if (!running) break;
    }
    notifyListeners();
  }

  Future<void> refreshStats({bool quiet = false}) async {
    try {
      final raw = await _invoke<String>('stats');
      final s = KernelStats.fromJsonString(raw);
      stats = s;
      final wasRunning = running;
      running = s != null;
      if (running) startError = null;
      if (!quiet || wasRunning != running) notifyListeners();
    } on PlatformException {
      if (!quiet) notifyListeners();
    }
  }

  Future<void> refreshRuleInfo() async {
    try {
      ruleInfo = RuleInfo.fromJsonString(await _invoke<String>('ruleInfo'));
      rulesDir = await _invoke<String>('rulesDir') ?? rulesDir;
      notifyListeners();
    } on PlatformException {
      // 静默：规则页显示空态
    }
  }

  Future<MatchResult?> matchTest(String domain) async {
    try {
      return MatchResult.fromJsonString(
          await _invoke<String>('match', {'domain': domain}));
    } on PlatformException {
      return null;
    }
  }

  /// 2s 周期轮询：运行中刷新统计；stats 变 null（进程被杀）即判停。
  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (running) refreshStats(quiet: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

/// 时长格式化（对齐鸿蒙端口径）。
String formatUptime(int sec) {
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  final s = sec % 60;
  if (h > 0) return '$h 小时 $m 分';
  if (m > 0) return '$m 分 $s 秒';
  return '$s 秒';
}

String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
