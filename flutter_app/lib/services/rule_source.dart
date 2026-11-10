import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

/// 订阅源管理（方向1 功能1）：在 Dart 侧复刻 internal/subscribe 的口径——
/// 条件 GET（If-None-Match/If-Modified-Since，304 视为未更新）、60s 超时、
/// 32MB 体积上限（流式计数）、最小有效行数 10、行数收缩 >50% 告警仍应用、
/// 临时文件 + rename 原子落盘、meta sidecar 记录 ETag/Last-Modified/行数。
///
/// 文件布局（全部 dart:io，路径由 'dragnet/native' 的 rulesDir 提供，
/// 不引 path_provider）：
///   filesDir/rules/           内核加载目录（*.txt 全量加载）
///   filesDir/rules/zzz-user-rules.txt   用户规则（拦截 ||d^ / 放行 @@||d^$important）
///   filesDir/config/app-config.json     自动更新开关 + 上次检查时间
///   filesDir/config/sources.json        订阅源配置
///   filesDir/config/sources/`<id>`.meta.json 下载元数据（字段名照抄 subscribe.go:84-89）

// ── 与 internal/subscribe 对齐的硬性常量 ────────────────────────────────────
const int maxListBytes = 32 << 20; // 单订阅体积上限 32MB（T4.3）
const int minListLines = 10; // 有效订阅最小非注释行数
const int shrinkWarnPct = 50; // 行数收缩告警阈值（仍应用）
const Duration fetchTimeout = Duration(seconds: 60);
const String subscriberUA = 'Dragnet-App/1.1';

/// 用户规则文件名（对齐 Windows 端 zzz-user-allow.txt 的 zzz 前缀习惯；
/// 内核按 *.txt 全量加载，前缀只是排序习惯）。
const String userRulesFileName = 'zzz-user-rules.txt';

// ── 纯函数（单测覆盖）──────────────────────────────────────────────────────

/// 统计非空、非注释（!/# 开头）行数（对齐 subscribe.go countRuleLines）。
int countRuleLines(String text) {
  var n = 0;
  for (final ln in text.split('\n')) {
    final s = ln.trim();
    if (s.isEmpty || s.startsWith('!') || s.startsWith('#')) continue;
    n++;
  }
  return n;
}

/// 域名合法性（同内核口径：[a-z0-9.-]、≤253、至少一个点；另拒空标签/首尾点）。
bool isValidDomain(String domain) {
  final d = domain.trim();
  if (d.isEmpty || d.length > 253) return false;
  if (!d.contains('.')) return false;
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(d)) return false;
  if (d.startsWith('.') || d.endsWith('.') || d.contains('..')) return false;
  return true;
}

/// 用户规则行拼接：拦截 `||domain^`；放行 `@@||domain^$important`
/// （$important 例外优先于订阅阻断，对齐 Windows 端 zzz-user-allow.txt 惯例）。
String formatUserRuleLine(String domain, {required bool allow}) =>
    allow ? '@@||$domain^\$important' : '||$domain^';

enum UserRuleKind { block, allow, other }

/// zzz-user-rules.txt 里的一行（other=无法识别的行，仅展示/删除）。
class UserRuleEntry {
  const UserRuleEntry({
    required this.raw,
    required this.kind,
    required this.domain,
  });

  final String raw;
  final UserRuleKind kind;
  final String domain;
}

/// 解析用户规则文件文本：跳过空行/!注释；识别两种规则行形态。
List<UserRuleEntry> parseUserRules(String text) {
  const allowSuffix = r'^$important';
  final out = <UserRuleEntry>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('!')) continue;
    if (line.startsWith('@@||') && line.endsWith(allowSuffix)) {
      final d = line.substring(4, line.length - allowSuffix.length);
      out.add(UserRuleEntry(
          raw: line, kind: UserRuleKind.allow, domain: d));
    } else if (line.startsWith('||') && line.endsWith('^')) {
      out.add(UserRuleEntry(
          raw: line,
          kind: UserRuleKind.block,
          domain: line.substring(2, line.length - 1)));
    } else {
      out.add(UserRuleEntry(raw: line, kind: UserRuleKind.other, domain: ''));
    }
  }
  return out;
}

// ── 出站 DNS 上游（M6 对齐鸿蒙 DragnetService.readDnsUp/writeDnsUp）────────
// 落 filesDir/config/dns-up.txt，VPN 启动时内核读取；UI 保存前校验 ip:port。

const String defaultDnsUp = '223.5.5.5:53';

/// ip:port 合法性（四段 0-255 + 端口 1-65535；对齐鸿蒙 2026-11-01 校验口径）。
bool isValidIpPort(String s) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})$')
      .firstMatch(s.trim());
  if (m == null) return false;
  for (var i = 1; i <= 4; i++) {
    if (int.parse(m.group(i)!) > 255) return false;
  }
  final port = int.parse(m.group(5)!);
  return port >= 1 && port <= 65535;
}

// ── 模型 ───────────────────────────────────────────────────────────────────

/// 应用级配置（filesDir/config/app-config.json）。
class AppConfig {
  AppConfig({
    required this.autoUpdateRules,
    this.lastRulesCheck = '',
    this.lastAppUpdateCheck = '',
  });

  bool autoUpdateRules;
  String lastRulesCheck; // RFC3339 或空
  String lastAppUpdateCheck; // RFC3339 或空

  factory AppConfig.defaults() => AppConfig(autoUpdateRules: true);

  Map<String, dynamic> toJson() => {
        'autoUpdateRules': autoUpdateRules,
        'lastRulesCheck': lastRulesCheck,
        'lastAppUpdateCheck': lastAppUpdateCheck,
      };

  static AppConfig? fromJsonString(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return AppConfig(
        autoUpdateRules: m['autoUpdateRules'] as bool? ?? true,
        lastRulesCheck: (m['lastRulesCheck'] as String?) ?? '',
        lastAppUpdateCheck: (m['lastAppUpdateCheck'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 订阅源配置（filesDir/config/sources.json 里的一个条目）。
class SourceConfig {
  const SourceConfig({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });

  final String id; // 文件名主干（rulesDir/<id>.txt）
  final String name;
  final String url;
  final bool enabled;

  SourceConfig withEnabled(bool v) =>
      SourceConfig(id: id, name: name, url: url, enabled: v);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'enabled': enabled};

  static SourceConfig? fromJson(Map<String, dynamic> m) {
    final id = (m['id'] as String?) ?? '';
    final url = (m['url'] as String?) ?? '';
    if (id.isEmpty || url.isEmpty) return null;
    return SourceConfig(
      id: id,
      name: (m['name'] as String?) ?? id,
      url: url,
      enabled: m['enabled'] as bool? ?? true,
    );
  }
}

/// 下载元数据 sidecar。字段名照抄 internal/subscribe/subscribe.go:84-89
/// （etag / last_modified / fetched_at / lines），fetched_at 用 RFC3339。
class SourceMeta {
  const SourceMeta({
    this.etag = '',
    this.lastModified = '',
    this.fetchedAt = '',
    this.lines = 0,
  });

  final String etag;
  final String lastModified;
  final String fetchedAt; // RFC3339 或空（=从未更新）
  final int lines;

  Map<String, dynamic> toJson() => {
        'etag': etag,
        'last_modified': lastModified,
        'fetched_at': fetchedAt,
        'lines': lines,
      };

  static SourceMeta? fromJsonString(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return SourceMeta(
        etag: (m['etag'] as String?) ?? '',
        lastModified: (m['last_modified'] as String?) ?? '',
        fetchedAt: (m['fetched_at'] as String?) ?? '',
        lines: (m['lines'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 单源抓取结论。
enum SourceFetchStatus { updated, notModified, error }

class SourceFetchResult {
  const SourceFetchResult({
    required this.status,
    this.lines,
    this.shrinkWarning = false,
    this.error,
  });

  final SourceFetchStatus status;
  final int? lines;
  final bool shrinkWarning; // 新行数 < 旧行数 50%（仍应用，UI 告警）
  final String? error;
}

/// 一轮全部更新的汇总。
class UpdateAllSummary {
  UpdateAllSummary({
    required this.updated,
    required this.skipped,
    required this.failed,
    required this.warnings,
  });

  final int updated;
  final int skipped;
  final int failed;
  final List<String> warnings; // 收缩告警等非致命提示

  bool get anyUpdated => updated > 0;
}

// ── 路径小工具（Android 路径恒为 POSIX，字符串拼接即可）────────────────────

String joinPath(String a, String b) =>
    a.endsWith('/') ? '$a$b' : '$a/$b';

String dirnameOf(String p) {
  final i = p.lastIndexOf('/');
  return i <= 0 ? p : p.substring(0, i);
}

String urlHost(String url) {
  try {
    return Uri.parse(url).host;
  } catch (_) {
    return url;
  }
}

String _rfc3339(DateTime t) => t.toUtc().toIso8601String();

/// 预置三源（照抄 internal/subscribe/subscribe.go DefaultConfig()，
/// id 按 App 侧约定：anti-ad / awavenue / hagezi-multi）。用户可删可改。
List<SourceConfig> defaultSources() => const [
      SourceConfig(
          id: 'anti-ad', name: 'anti-AD', url: 'https://anti-ad.net/adguard.txt'),
      SourceConfig(
          id: 'awavenue',
          name: 'AWAvenue',
          url:
              'https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Adguard.txt'),
      SourceConfig(
          id: 'hagezi-multi',
          name: 'hagezi',
          url:
              'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt'),
    ];

// ── 服务 ───────────────────────────────────────────────────────────────────

/// 订阅源 + 应用配置 + 用户规则的文件面（ChangeNotifier：列表/meta 变更即通知）。
/// 磁盘读写只在 Android 上执行（App 是 Android 专用壳；测试环境纯内存），
/// 全部异常捕获 + debugPrint，绝不向调用方抛（init 阶段不允许阻塞失败）。
class SubscriptionService extends ChangeNotifier {
  static final SubscriptionService instance = SubscriptionService._();

  SubscriptionService._();

  List<SourceConfig> sources = [];
  final Map<String, SourceMeta> metas = {};
  final Map<String, String> lastErrors = {}; // 会话内"上次错误"（不持久化）
  String rulesDir = '';
  String configDir = '';
  bool loaded = false;

  AppConfig appConfig = AppConfig.defaults();

  http.Client? _client;

  bool get _canWrite => Platform.isAndroid;

  String get _sourcesJsonPath => joinPath(configDir, 'sources.json');
  String get _appConfigPath => joinPath(configDir, 'app-config.json');
  String get _userRulesPath => joinPath(rulesDir, userRulesFileName);
  String get _metaDir => joinPath(configDir, 'sources');
  String get _dnsUpPath => joinPath(configDir, 'dns-up.txt');

  String sourceRulePath(String id) => joinPath(rulesDir, '$id.txt');
  String sourceMetaPath(String id) => joinPath(_metaDir, '$id.meta.json');

  http.Client get _httpClient => _client ??= http.Client();

  /// 用通道给的 rulesDir 初始化（幂等）。rulesDir 为空时不做任何事。
  Future<void> ensureLoaded(String dir) async {
    if (dir.isEmpty) return;
    if (loaded && rulesDir == dir) return;
    rulesDir = dir;
    configDir = joinPath(dirnameOf(dir), 'config');
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    if (!_canWrite) {
      sources = defaultSources();
      loaded = true;
      notifyListeners();
      return;
    }
    try {
      final f = File(_sourcesJsonPath);
      if (await f.exists()) {
        sources = parseSourcesConfig(await f.readAsString());
      } else {
        sources = defaultSources();
        await _writeSourcesConfig(); // 首次创建：预置三源
      }
    } catch (e) {
      debugPrint('订阅配置读取失败，用默认配置: $e');
      sources = defaultSources();
    }
    if (sources.isEmpty) sources = defaultSources();
    for (final s in sources) {
      try {
        final mf = File(sourceMetaPath(s.id));
        if (await mf.exists()) {
          final m = SourceMeta.fromJsonString(await mf.readAsString());
          if (m != null) metas[s.id] = m;
        }
      } catch (_) {}
    }
    try {
      final af = File(_appConfigPath);
      if (await af.exists()) {
        final c = AppConfig.fromJsonString(await af.readAsString());
        if (c != null) appConfig = c;
      }
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  Future<void> _writeSourcesConfig() async {
    if (!_canWrite) return;
    final dir = Directory(configDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final body = jsonEncode({
      'sources': [for (final s in sources) s.toJson()],
    });
    await File(_sourcesJsonPath).writeAsString(body, flush: true);
  }

  /// 保存 app-config（增量字段）。每轮规则检查（含手动）后回写 lastRulesCheck。
  Future<void> saveAppConfig({
    bool? autoUpdateRules,
    DateTime? lastRulesCheck,
    DateTime? lastAppUpdateCheck,
  }) async {
    if (autoUpdateRules != null) appConfig.autoUpdateRules = autoUpdateRules;
    if (lastRulesCheck != null) {
      appConfig.lastRulesCheck = _rfc3339(lastRulesCheck);
    }
    if (lastAppUpdateCheck != null) {
      appConfig.lastAppUpdateCheck = _rfc3339(lastAppUpdateCheck);
    }
    if (_canWrite) {
      try {
        final dir = Directory(configDir);
        if (!await dir.exists()) await dir.create(recursive: true);
        await File(_appConfigPath)
            .writeAsString(jsonEncode(appConfig.toJson()), flush: true);
      } catch (e) {
        debugPrint('app-config 写盘失败: $e');
      }
    }
    notifyListeners();
  }

  /// 添加订阅源（URL 校验 https?:// 由调用方先做）。id 由 name 派生并去重。
  Future<SourceConfig> addSource(String name, String url) async {
    var id = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (id.isEmpty) id = 'source';
    final taken = sources.map((s) => s.id).toSet();
    var cand = id;
    var n = 2;
    while (taken.contains(cand)) {
      cand = '$id-${n++}';
    }
    final src = SourceConfig(id: cand, name: name.trim(), url: url.trim());
    sources.add(src);
    try {
      await _writeSourcesConfig();
    } catch (e) {
      debugPrint('订阅配置写盘失败: $e');
    }
    notifyListeners();
    return src;
  }

  /// 启用/停用（停用只跳过更新，保留配置与已下载文件）。
  Future<void> setEnabled(String id, bool enabled) async {
    sources = [
      for (final s in sources)
        if (s.id == id) s.withEnabled(enabled) else s,
    ];
    try {
      await _writeSourcesConfig();
    } catch (e) {
      debugPrint('订阅配置写盘失败: $e');
    }
    notifyListeners();
  }

  /// 删除源：配置 + rulesDir/`<id>`.txt + meta 一并清掉（调用方随后 reloadRules）。
  Future<void> deleteSource(String id) async {
    sources = [for (final s in sources) if (s.id != id) s];
    metas.remove(id);
    lastErrors.remove(id);
    try {
      await _writeSourcesConfig();
    } catch (e) {
      debugPrint('订阅配置写盘失败: $e');
    }
    if (_canWrite) {
      try {
        final f = File(sourceRulePath(id));
        if (await f.exists()) await f.delete();
      } catch (_) {}
      try {
        final m = File(sourceMetaPath(id));
        if (await m.exists()) await m.delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 抓取单源（对齐 subscribe.go fetchOne）。不抛异常，结论走返回值。
  Future<SourceFetchResult> fetchOne(SourceConfig s) async {
    final old = metas[s.id] ?? const SourceMeta();
    SourceFetchResult fail(String msg) {
      lastErrors[s.id] = msg;
      notifyListeners();
      return SourceFetchResult(status: SourceFetchStatus.error, error: msg);
    }

    final req = http.Request('GET', Uri.parse(s.url));
    if (old.etag.isNotEmpty) req.headers['If-None-Match'] = old.etag;
    if (old.lastModified.isNotEmpty) {
      req.headers['If-Modified-Since'] = old.lastModified;
    }
    req.headers['User-Agent'] = subscriberUA;

    http.StreamedResponse resp;
    try {
      resp = await _httpClient.send(req).timeout(fetchTimeout);
    } on TimeoutException {
      return fail('下载超时（60s）');
    } catch (e) {
      return fail('下载失败: $e');
    }

    try {
      if (resp.statusCode == 304) {
        lastErrors.remove(s.id);
        notifyListeners();
        return const SourceFetchResult(status: SourceFetchStatus.notModified);
      }
      if (resp.statusCode != 200) {
        await _drain(resp);
        return fail('HTTP ${resp.statusCode}');
      }
      if (resp.contentLength != null && resp.contentLength! > maxListBytes) {
        await _drain(resp);
        return fail('超过单订阅体积上限 32MB');
      }

      // 流式计数（Content-Length 缺省/分块时兜底），超限立即中止（T4.3）。
      final bytes = await _readLimited(resp);
      if (bytes == null) return fail('超过单订阅体积上限 32MB');

      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = countRuleLines(text);
      if (lines < minListLines) {
        return fail('非注释行数 $lines 低于最小值 $minListLines，疑似坏响应');
      }
      final shrink =
          old.lines > 0 && lines * 100 < old.lines * (100 - shrinkWarnPct);

      // 原子落盘：同目录临时文件 + rename（rename 在 POSIX/Windows 均替换目标）。
      try {
        final dir = Directory(rulesDir);
        if (!await dir.exists()) await dir.create(recursive: true);
        final tmp = File(joinPath(rulesDir, '.sub-${s.id}.tmp'));
        await tmp.writeAsBytes(bytes, flush: true);
        try {
          await tmp.rename(sourceRulePath(s.id));
        } catch (_) {
          await tmp.delete();
          rethrow;
        }
      } catch (e) {
        return fail('规则文件落盘失败: $e');
      }

      final next = SourceMeta(
        etag: resp.headers['etag'] ?? '',
        lastModified: resp.headers['last-modified'] ?? '',
        fetchedAt: _rfc3339(DateTime.now()),
        lines: lines,
      );
      metas[s.id] = next;
      lastErrors.remove(s.id);
      try {
        final md = Directory(_metaDir);
        if (!await md.exists()) await md.create(recursive: true);
        await File(sourceMetaPath(s.id))
            .writeAsString(jsonEncode(next.toJson()), flush: true);
      } catch (e) {
        debugPrint('meta 写盘失败（不影响本轮生效）: $e');
      }
      notifyListeners();
      return SourceFetchResult(
          status: SourceFetchStatus.updated,
          lines: lines,
          shrinkWarning: shrink);
    } finally {
      _drainQuietly(resp);
    }
  }

  void _drainQuietly(http.StreamedResponse resp) {
    // 兜底消费残余字节，避免连接悬挂（已读完的 drain 立即返回）
    unawaited(resp.stream.drain<void>().catchError((_) {}));
  }

  Future<void> _drain(http.StreamedResponse resp) async {
    try {
      await resp.stream.drain<void>().timeout(fetchTimeout);
    } catch (_) {}
  }

  Future<List<int>?> _readLimited(http.StreamedResponse resp) async {
    final builder = BytesBuilder(copy: false);
    final done = Completer<List<int>?>();
    // late final：回调在 listen 赋值完成后才会触发，可直接引用
    late final StreamSubscription<List<int>> sub;
    sub = resp.stream.listen((chunk) {
      builder.add(chunk);
      if (builder.length > maxListBytes && !done.isCompleted) {
        done.complete(null); // 超限：丢弃
        sub.cancel();
      }
    }, onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    }, cancelOnError: true);
    try {
      return await done.future.timeout(fetchTimeout);
    } on TimeoutException {
      await sub.cancel();
      return null;
    }
  }

  /// 顺序抓取全部启用源（停用源跳过但保留配置）。
  /// onProgress(done, total, name)：done=已完成的数量，name=即将更新的源。
  Future<UpdateAllSummary> updateAll({
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final targets = sources.where((s) => s.enabled).toList();
    var updated = 0, skipped = 0, failed = 0;
    final warnings = <String>[];
    var done = 0;
    for (final s in targets) {
      onProgress?.call(done, targets.length, s.name);
      final r = await fetchOne(s);
      switch (r.status) {
        case SourceFetchStatus.updated:
          updated++;
          if (r.shrinkWarning) {
            warnings.add(
                '${s.name}：行数收缩到 ${r.lines}（>$shrinkWarnPct%），请核对订阅源');
          }
        case SourceFetchStatus.notModified:
          skipped++;
        case SourceFetchStatus.error:
          failed++;
      }
      done++;
    }
    onProgress?.call(done, targets.length, '');
    return UpdateAllSummary(
        updated: updated, skipped: skipped, failed: failed, warnings: warnings);
  }

  // ── 用户规则（zzz-user-rules.txt）─────────────────────────────────────────

  Future<List<String>> readUserRuleLines() async {
    try {
      final f = File(_userRulesPath);
      if (!await f.exists()) return [];
      final text = await f.readAsString();
      final lines = text.split('\n');
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      return lines;
    } catch (e) {
      debugPrint('用户规则读取失败: $e');
      return [];
    }
  }

  Future<void> writeUserRuleLines(List<String> lines) async {
    final dir = Directory(rulesDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final tmp = File(joinPath(rulesDir, '.$userRulesFileName.tmp'));
    await tmp.writeAsString(
        lines.isEmpty ? '' : '${lines.join('\n')}\n',
        flush: true);
    await tmp.rename(_userRulesPath);
  }

  // ── 出站 DNS 上游（内核 startVpn 时读取；UI 保存前校验，服务读取兜底再校验）──

  Future<String> readDnsUp() async {
    if (!_canWrite) return defaultDnsUp;
    try {
      final f = File(_dnsUpPath);
      if (!await f.exists()) return defaultDnsUp;
      final text = (await f.readAsString()).trim();
      return text.isEmpty ? defaultDnsUp : text;
    } catch (e) {
      debugPrint('dns-up 读取失败: $e');
      return defaultDnsUp;
    }
  }

  Future<void> writeDnsUp(String value) async {
    if (!_canWrite) return; // 测试环境纯内存 no-op（对齐本服务其他写路径）
    try {
      final dir = Directory(configDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final tmp = File('$_dnsUpPath.tmp');
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(_dnsUpPath);
    } catch (e) {
      debugPrint('dns-up 写盘失败: $e');
    }
  }

  // ── 种子分发（M4-R1 规则可见性）────────────────────────────────────────────

  /// 首启种子：rulesDir 不存在或无 *.txt 时，把随包分发的 starter.txt /
  /// protected-allow.txt（assets，外部可见文件，M4-R1 规则可见性硬约束）
  /// 写入 rulesDir；已存在同名文件不覆盖。
  Future<void> seedRulesIfEmpty() async {
    final dir = Directory(rulesDir);
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.txt')) return;
      }
    }
    await dir.create(recursive: true);
    const seeds = [
      ('assets/rules/starter.txt', 'starter.txt'),
      ('assets/rules/protected-allow.txt', 'protected-allow.txt'),
    ];
    for (final (asset, name) in seeds) {
      final target = File(joinPath(rulesDir, name));
      if (await target.exists()) continue; // 已存在不覆盖
      await target.writeAsString(await rootBundle.loadString(asset),
          flush: true);
    }
  }

  @override
  void dispose() {
    _client?.close();
    _client = null;
    super.dispose();
  }
}

/// 解析 sources.json 文本（纯函数，供单测）。
List<SourceConfig> parseSourcesConfig(String raw) {
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final list = (m['sources'] as List?) ?? const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>)
          if (SourceConfig.fromJson(e) != null) SourceConfig.fromJson(e)!,
    ];
  } catch (_) {
    return [];
  }
}
