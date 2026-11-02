import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_meta.dart';

/// App 自更新检查（方向1 功能3）：查 GitHub releases 里最新的 app-v* tag，
/// 与本机 [appVersion] 做 semver 比较。只做检查与提示，不做下载/安装
/// （下载地址文本框 + 复制链接，由用户自取，不引 url_launcher）。
///
/// 网络仅为普通应用级 HTTPS GET，不触碰系统网络配置。

const _releasesUrl =
    'https://api.github.com/repos/SYTKILLER/Dragnet/releases?per_page=10';

/// 单条 release 检查结果。
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.downloadUrl,
  });

  final String tag; // 如 app-v1.2.0
  final String version; // 如 1.2.0
  final String notes; // release body 原文（UI 侧截断展示）
  final String downloadUrl; // 优先 apk 资产，否则 release 页面

  static AppRelease? fromJson(Map<String, dynamic> m) {
    final tag = (m['tag_name'] as String?) ?? '';
    if (!tag.startsWith('app-v')) return null;
    final assets = (m['assets'] as List?) ?? const [];
    String url = (m['html_url'] as String?) ?? '';
    for (final a in assets) {
      final name = (a as Map<String, dynamic>)['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        url = (a['browser_download_url'] as String?) ?? url;
        break;
      }
    }
    return AppRelease(
      tag: tag,
      version: tag.substring('app-v'.length),
      notes: (m['body'] as String?) ?? '',
      downloadUrl: url,
    );
  }
}

/// 一次检查的结论。
enum AppUpdateStatus { upToDate, available, error }

class AppUpdateResult {
  const AppUpdateResult({
    required this.status,
    this.release,
    this.message,
  });

  final AppUpdateStatus status;
  final AppRelease? release;
  final String? message; // status=error 时的原因

  bool get isNewVersion => status == AppUpdateStatus.available;
}

/// semver 比较（容忍 v 前缀与两段式 1.2）：负=a 小于 b，0=相等，正=a 大于 b。
/// 非数字段按 0 处理；预发布段（-beta）不解析，取 '-' 前主干。
int compareSemver(String a, String b) {
  final va = _semverParts(a);
  final vb = _semverParts(b);
  for (var i = 0; i < 3; i++) {
    final c = va[i].compareTo(vb[i]);
    if (c != 0) return c;
  }
  return 0;
}

List<int> _semverParts(String s) {
  var t = s.trim().toLowerCase();
  if (t.startsWith('v')) t = t.substring(1);
  final dash = t.indexOf('-');
  if (dash >= 0) t = t.substring(0, dash);
  final parts = t.split('.');
  return [
    for (var i = 0; i < 3; i++)
      i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0,
  ];
}

/// 拉取 releases 并判定是否比 [currentVersion] 新。
/// 403/限流/超时/解析失败一律按"检查失败"处理（status=error）。
/// 响应结构：`List<dynamic>`（releases 数组，按时间倒序）。
Future<AppUpdateResult> checkAppUpdate({
  String currentVersion = appVersion,
  http.Client? client,
  Duration timeout = const Duration(seconds: 60),
}) async {
  http.Client? own;
  var c = client;
  if (c == null) {
    own = http.Client();
    c = own;
  }
  try {
    final resp = await c
        .get(Uri.parse(_releasesUrl), headers: {
          'User-Agent': 'Dragnet-App/1.1',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        })
        .timeout(timeout);
    if (resp.statusCode == 403) {
      return const AppUpdateResult(
          status: AppUpdateStatus.error, message: 'GitHub API 限流（403），稍后再试');
    }
    if (resp.statusCode != 200) {
      return AppUpdateResult(
          status: AppUpdateStatus.error, message: 'HTTP ${resp.statusCode}');
    }
    final List<dynamic> releases;
    try {
      releases = jsonDecode(utf8.decode(resp.bodyBytes)) as List<dynamic>;
    } catch (_) {
      return const AppUpdateResult(
          status: AppUpdateStatus.error, message: '响应解析失败');
    }
    AppRelease? latest;
    for (final r in releases) {
      if (r is! Map<String, dynamic>) continue;
      final rel = AppRelease.fromJson(r);
      if (rel == null) continue;
      // releases 按时间倒序：第一个 app-v* 即最新
      latest = rel;
      break;
    }
    if (latest == null) {
      return const AppUpdateResult(status: AppUpdateStatus.upToDate);
    }
    if (compareSemver(latest.version, currentVersion) > 0) {
      return AppUpdateResult(
          status: AppUpdateStatus.available, release: latest);
    }
    return const AppUpdateResult(status: AppUpdateStatus.upToDate);
  } on TimeoutException {
    return const AppUpdateResult(
        status: AppUpdateStatus.error, message: '检查超时（60s）');
  } catch (e) {
    return AppUpdateResult(status: AppUpdateStatus.error, message: '$e');
  } finally {
    own?.close();
  }
}

/// "有新版本"全局提示状态：静默检查命中后置位，设置页角标消费。
class AppUpdateNotifier extends ChangeNotifier {
  static final AppUpdateNotifier instance = AppUpdateNotifier._();

  AppUpdateNotifier._();

  bool updateAvailable = false;
  AppRelease? release;

  void markAvailable(AppRelease rel) {
    updateAvailable = true;
    release = rel;
    notifyListeners();
  }

  void clear() {
    if (!updateAvailable) return;
    updateAvailable = false;
    release = null;
    notifyListeners();
  }
}

/// 发布说明摘要（弹窗展示用）：截 500 字。
String summarizeNotes(String notes, {int maxLen = 500}) {
  final t = notes.replaceAll('\r\n', '\n').trim();
  if (t.length <= maxLen) return t;
  return '${t.substring(0, maxLen)}…';
}
