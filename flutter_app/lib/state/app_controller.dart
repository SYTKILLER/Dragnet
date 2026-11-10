import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/app_update.dart';
import '../services/rule_source.dart';

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

/// 转发日志单条（nativeLogs JSON events 元素；ts 为毫秒）。
/// 语义：block=命中规则阻断；allow=命中白名单例外；forward=DNS 正常转发；
/// relay=TCP/UDP 正常中继。
class LogEvent {
  const LogEvent({
    required this.id,
    required this.ts,
    required this.kind,
    required this.action,
    required this.domain,
    required this.rule,
    required this.list,
    required this.dest,
    required this.process,
  });

  final int id;
  final int ts;
  final String kind; // dns | tcp | udp
  final String action; // block | allow | forward | relay
  final String domain;
  final String rule;
  final String list;
  final String dest;
  final String process;

  static LogEvent? fromJson(Map<String, dynamic> m) {
    final id = (m['id'] as num?)?.toInt();
    if (id == null) return null;
    return LogEvent(
      id: id,
      ts: (m['ts'] as num?)?.toInt() ?? 0,
      kind: (m['kind'] as String?) ?? '',
      action: (m['action'] as String?) ?? '',
      domain: (m['domain'] as String?) ?? '',
      rule: (m['rule'] as String?) ?? '',
      list: (m['list'] as String?) ?? '',
      dest: (m['dest'] as String?) ?? '',
      process: (m['process'] as String?) ?? '',
    );
  }
}

/// 一次 logs 拉取的返回（cursor=内核侧最大 id；events 升序）。
class LogsChunk {
  const LogsChunk({required this.cursor, required this.events});

  final int cursor;
  final List<LogEvent> events;
}

/// 原生桥 + 全局状态。内核自 M6-A（2026-11-11）起运行在独立 :vpn 进程
///（对齐鸿蒙壳 UI/VPN 分离架构；通道契约不变，Java 侧经 Messenger IPC 透传），
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

  /// lastStartRc≠0 时的内核 startVpn 失败原因（lastError 通道）。
  int lastStartRc = 0;
  String? kernelLastError;

  Timer? _pollTimer;
  Timer? _ruleAutoTimer;
  bool _bgStarted = false;

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
      await refreshStartFailure(); // lastStartRc≠0 时透出 lastError 具体原因
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
      if (!running && wasRunning) {
        // 运行中→停止（内核崩溃/被杀）：查询 lastStartRc/lastError 透出原因
        unawaited(refreshStartFailure());
      }
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

  /// 热切换重载规则（'reloadRules'，复用 nativeLoadRules 原子热切换，
  /// 运行中调用也生效）。返回 0=成功，负数=失败。
  Future<int> reloadRules() async {
    try {
      return await _invoke<int>('reloadRules', {'dir': rulesDir}) ?? -1;
    } on PlatformException {
      return -1;
    }
  }

  /// 增量拉取转发日志（'logs'）。返回 null=通道异常（调用方忽略本次）；
  /// 旧 .so 无符号时原生侧返回 null → 当空处理（cursor 原样带回）。
  Future<LogsChunk?> fetchLogs(int cursor) async {
    try {
      final raw = await _invoke<String>('logs', {'cursor': cursor});
      if (raw == null) return LogsChunk(cursor: cursor, events: const []);
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final c = (m['cursor'] as num?)?.toInt() ?? cursor;
      final events = <LogEvent>[];
      for (final e in (m['events'] as List?) ?? const []) {
        if (e is Map<String, dynamic>) {
          final ev = LogEvent.fromJson(e);
          if (ev != null) events.add(ev);
        }
      }
      return LogsChunk(cursor: c, events: events);
    } on PlatformException {
      return null;
    }
  }

  /// 内核未运行时的失败原因透出：lastStartRc≠0 → 取 lastError 具体文本。
  Future<void> refreshStartFailure() async {
    try {
      final rc = await _invoke<int>('lastStartRc');
      lastStartRc = rc ?? 0;
      kernelLastError = null;
      if (lastStartRc != 0) {
        try {
          kernelLastError = await _invoke<String>('lastError');
        } on PlatformException {
          kernelLastError = null;
        }
      }
      notifyListeners();
    } on PlatformException {
      // 静默：桥不可用时无信息可透出
    }
  }

  /// 一轮全部订阅更新（手动/自动共用）：顺序逐源拉取 → 回写 lastRulesCheck
  /// → 有更新则 reloadRules 热切换并刷新 ruleInfo。
  Future<UpdateAllSummary> updateAllSources({
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final svc = SubscriptionService.instance;
    final summary = await svc.updateAll(onProgress: onProgress);
    await svc.saveAppConfig(lastRulesCheck: DateTime.now());
    if (summary.anyUpdated) {
      final rc = await reloadRules();
      await refreshRuleInfo();
      if (rc != 0) debugPrint('规则热切换失败 rc=$rc（沿用旧引擎）');
    }
    return summary;
  }

  /// 用户规则写文件 → reloadRules → 返回 rc（UI snackbar 反馈用）。
  Future<int> applyUserRules(List<String> lines) async {
    final svc = SubscriptionService.instance;
    try {
      await svc.writeUserRuleLines(lines);
    } catch (e) {
      debugPrint('用户规则写盘失败: $e');
      return -1;
    }
    return reloadRules();
  }

  /// main() 启动钩子：种子规则写入 + 订阅/App 自动检查调度。
  /// ⛔ 全程静默失败（try/catch + debugPrint），不做任何可能阻塞 init 的事。
  Future<void> startBackgroundServices() async {
    if (_bgStarted) return;
    _bgStarted = true;
    await refreshRuleInfo();
    final svc = SubscriptionService.instance;
    if (rulesDir.isEmpty) return;
    try {
      await svc.ensureLoaded(rulesDir);
    } catch (e) {
      debugPrint('订阅服务初始化失败: $e');
      return;
    }
    try {
      await svc.seedRulesIfEmpty(); // M4-R1：首启无 *.txt 时落盘种子
    } catch (e) {
      debugPrint('种子规则写入失败: $e');
    }
    if (!running) unawaited(refreshStartFailure());
    unawaited(_autoRuleCheckOnce());
    _ruleAutoTimer?.cancel();
    _ruleAutoTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(_autoRuleCheck());
    });
    unawaited(_autoAppUpdateCheck());
  }

  Future<void> _autoRuleCheckOnce() async {
    try {
      final cfg = SubscriptionService.instance.appConfig;
      if (!cfg.autoUpdateRules) return;
      final last = DateTime.tryParse(cfg.lastRulesCheck);
      if (last != null &&
          DateTime.now().difference(last) <= const Duration(hours: 6)) {
        return;
      }
      await updateAllSources(); // 后台静默，完成后已刷新 ruleInfo
    } catch (e) {
      debugPrint('自动规则检查失败: $e');
    }
  }

  Future<void> _autoRuleCheck() async {
    try {
      if (!SubscriptionService.instance.appConfig.autoUpdateRules) return;
      await updateAllSources();
    } catch (e) {
      debugPrint('周期规则检查失败: $e');
    }
  }

  Future<void> _autoAppUpdateCheck() async {
    try {
      final cfg = SubscriptionService.instance.appConfig;
      final last = DateTime.tryParse(cfg.lastAppUpdateCheck);
      if (last != null &&
          DateTime.now().difference(last) <= const Duration(hours: 24)) {
        return;
      }
      final r = await checkAppUpdate();
      await SubscriptionService.instance
          .saveAppConfig(lastAppUpdateCheck: DateTime.now());
      if (r.isNewVersion && r.release != null) {
        AppUpdateNotifier.instance.markAvailable(r.release!); // 设置页角标提示一次
      }
    } catch (e) {
      debugPrint('App 自更新检查失败: $e');
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
    _ruleAutoTimer?.cancel();
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
