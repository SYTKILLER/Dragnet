// 方向1 应用侧四功能——纯 Dart 单测（无通道/无文件 IO）：
// semver 比较、用户规则行格式化、域名校验、规则行计数、
// 用户规则解析、meta/sources/app-config JSON 解析、日志事件解析。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/services/app_update.dart';
import 'package:dragnet_app/services/rule_source.dart';
import 'package:dragnet_app/state/app_controller.dart';

void main() {
  group('compareSemver（App 自更新版本比较）', () {
    test('相等版本判 0', () {
      expect(compareSemver('1.1.0', '1.1.0'), 0);
    });
    test('补丁位/主次位大小比较', () {
      expect(compareSemver('1.2.1', '1.2.0'), greaterThan(0));
      expect(compareSemver('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareSemver('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareSemver('1.0.9', '1.1.0'), lessThan(0));
    });
    test('容忍 v 前缀与两段式', () {
      expect(compareSemver('v1.2.0', '1.2.0'), 0);
      expect(compareSemver('1.2', '1.2.0'), 0);
      expect(compareSemver('v2', '1.9.9'), greaterThan(0));
    });
    test('release tag 场景：app-v1.2.0 比本机 1.1.0 新', () {
      expect(compareSemver('1.2.0', '1.1.0'), greaterThan(0));
    });
  });


  group('isValidIpPort（出站 DNS 上游校验，对齐鸿蒙口径）', () {
    test('合法形态', () {
      expect(isValidIpPort('223.5.5.5:53'), true);
      expect(isValidIpPort('119.29.29.29:53'), true);
      expect(isValidIpPort('1.1.1.1:65535'), true);
      expect(isValidIpPort(' 223.5.5.5:53 '), true); // 容忍首尾空白
    });
    test('非法形态', () {
      expect(isValidIpPort(''), false);
      expect(isValidIpPort('223.5.5.5'), false);        // 缺端口
      expect(isValidIpPort('223.5.5.5:0'), false);      // 端口 0
      expect(isValidIpPort('223.5.5.5:70000'), false);  // 端口越界
      expect(isValidIpPort('256.5.5.5:53'), false);     // 段越界
      expect(isValidIpPort('dns.example.com:53'), false);
      expect(isValidIpPort('223.5.5.5:53.1'), false);
    });
  });

  group('formatUserRuleLine（zzz-user-rules.txt 行格式）', () {
    test('拦截形态 ||domain^', () {
      expect(formatUserRuleLine('ads.example.com', allow: false),
          '||ads.example.com^');
    });
    test('放行形态 @@||domain^\$important', () {
      expect(formatUserRuleLine('alipay.com', allow: true),
          '@@||alipay.com^\$important');
    });
    test('两种形态都能被 parseUserRules 还原', () {
      final text = [
        '! 注释行',
        formatUserRuleLine('ads.example.com', allow: false),
        formatUserRuleLine('alipay.com', allow: true),
      ].join('\n');
      final entries = parseUserRules(text);
      expect(entries, hasLength(2));
      expect(entries[0].kind, UserRuleKind.block);
      expect(entries[0].domain, 'ads.example.com');
      expect(entries[0].raw, '||ads.example.com^');
      expect(entries[1].kind, UserRuleKind.allow);
      expect(entries[1].domain, 'alipay.com');
      expect(entries[1].raw, '@@||alipay.com^\$important');
    });
    test('注释/空行/无法识别行走 other 或被跳过', () {
      final entries = parseUserRules('! c\n\n不是规则行\n||ok.com^\n');
      expect(entries, hasLength(2));
      expect(entries[0].kind, UserRuleKind.other);
      expect(entries[0].raw, '不是规则行');
      expect(entries[1].kind, UserRuleKind.block);
      expect(entries[1].domain, 'ok.com');
    });
  });

  group('isValidDomain（与内核同口径）', () {
    test('合法域名', () {
      expect(isValidDomain('ads.example.com'), isTrue);
      expect(isValidDomain('a-b.c.io'), isTrue);
      expect(isValidDomain('12379.cn'), isTrue);
    });
    test('非法：无点/超长/坏字符/空标签', () {
      expect(isValidDomain('localhost'), isFalse); // 无点
      expect(isValidDomain('${'a' * 250}.com'), isFalse); // >253
      expect(isValidDomain('bad_domain.com'), isFalse); // 下划线
      expect(isValidDomain('UPPER.com'), isFalse); // 大写（先 lower 再校验）
      expect(isValidDomain('a..b.com'), isFalse); // 空标签
      expect(isValidDomain('.example.com'), isFalse); // 首点
      expect(isValidDomain(''), isFalse);
    });
  });

  group('countRuleLines（对齐 subscribe.go countRuleLines）', () {
    test('跳过空行/!/# 注释', () {
      const text = '||a.com^\n\n! 注释\n# 注释2\n  ||b.com^  \n||c.com^';
      expect(countRuleLines(text), 3);
    });
    test('全注释为 0（低于最小行数会被拒）', () {
      expect(countRuleLines('! a\n! b\n'), 0);
    });
  });

  group('SourceMeta（照抄 subscribe.go:84-89 字段名）', () {
    test('JSON 往返 + Go 字段名', () {
      const raw = '{"etag":"W/\\"abc\\"","last_modified":"Tue, 01 Jan 2026 '
          '00:00:00 GMT","fetched_at":"2026-11-02T08:00:00.000Z","lines":12345}';
      final m = SourceMeta.fromJsonString(raw);
      expect(m, isNotNull);
      expect(m!.etag, 'W/"abc"');
      expect(m.lastModified, contains('GMT'));
      expect(m.fetchedAt, '2026-11-02T08:00:00.000Z');
      expect(m.lines, 12345);
      final back = SourceMeta.fromJsonString(jsonEncode(m.toJson()));
      expect(back!.lines, 12345);
      expect(back.toJson().containsKey('last_modified'), isTrue);
    });
    test('坏 JSON 返回 null', () {
      expect(SourceMeta.fromJsonString('not-json'), isNull);
    });
  });

  group('parseSourcesConfig（sources.json）', () {
    test('解析 + enabled 缺省为 true', () {
      const raw = '{"sources":['
          '{"id":"anti-ad","name":"anti-AD","url":"https://anti-ad.net/adguard.txt","enabled":true},'
          '{"id":"x","name":"X","url":"https://x.com/a.txt"}'
          ']}';
      final list = parseSourcesConfig(raw);
      expect(list, hasLength(2));
      expect(list[0].id, 'anti-ad');
      expect(list[1].enabled, isTrue);
    });
    test('预置三源 id 与订阅 URL 固定', () {
      final defs = defaultSources();
      expect(defs.map((s) => s.id).toList(),
          ['anti-ad', 'awavenue', 'hagezi-multi']);
      expect(defs[0].url, 'https://anti-ad.net/adguard.txt');
    });
    test('坏 JSON 返回空列表', () {
      expect(parseSourcesConfig('{oops'), isEmpty);
    });
  });

  group('AppConfig（app-config.json）', () {
    test('解析与默认值', () {
      final c = AppConfig.fromJsonString(
          '{"autoUpdateRules":false,"lastRulesCheck":"2026-11-02T00:00:00.000Z",'
          '"lastAppUpdateCheck":""}');
      expect(c!.autoUpdateRules, isFalse);
      expect(c.lastRulesCheck, isNotEmpty);
      expect(AppConfig.fromJsonString('bad'), isNull);
      expect(AppConfig.defaults().autoUpdateRules, isTrue);
    });
  });

  group('LogEvent（logs 通道 JSON）', () {
    test('解析全字段与缺省', () {
      final e = LogEvent.fromJson(const {
        'id': 42,
        'ts': 1730000000000,
        'kind': 'dns',
        'action': 'block',
        'domain': 'ads.example.com',
        'rule': '||ads.example.com^',
        'list': 'anti-ad',
        'dest': '',
        'process': '',
      })!;
      expect(e.id, 42);
      expect(e.action, 'block');
      expect(e.kind, 'dns');
      expect(e.domain, 'ads.example.com');
      expect(LogEvent.fromJson(const {'ts': 1}), isNull); // 无 id → 丢弃
    });
    test('LogsChunk JSON 解析（cursor + events 升序）', () {
      const raw =
          '{"cursor":7,"events":[{"id":6,"ts":1,"kind":"tcp","action":"relay"},'
          '{"id":7,"ts":2,"kind":"dns","action":"forward"}]}';
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final events = [
        for (final e in m['events'] as List) LogEvent.fromJson(e as Map<String, dynamic>)!,
      ];
      expect(m['cursor'], 7);
      expect(events.map((e) => e.id).toList(), [6, 7]);
      expect(events[0].action, 'relay');
    });
  });

  group('路径与工具', () {
    test('joinPath / dirnameOf / urlHost', () {
      expect(joinPath('/data/app/files', 'rules'), '/data/app/files/rules');
      expect(dirnameOf('/data/app/files/rules'), '/data/app/files');
      expect(urlHost('https://anti-ad.net/adguard.txt'), 'anti-ad.net');
    });
  });

  group('AppRelease（GitHub releases）', () {
    test('取 app-v tag 并解析版本与 apk 资产', () {
      final rel = AppRelease.fromJson(const {
        'tag_name': 'app-v1.2.0',
        'html_url': 'https://github.com/SYTKILLER/Dragnet/releases/tag/app-v1.2.0',
        'body': '修复若干问题',
        'assets': [
          {
            'name': 'dragnet-app.apk',
            'browser_download_url': 'https://github.com/x/dragnet-1.2.0.apk'
          }
        ],
      })!;
      expect(rel.version, '1.2.0');
      expect(rel.downloadUrl, 'https://github.com/x/dragnet-1.2.0.apk');
      expect(AppRelease.fromJson(const {'tag_name': 'kernel-v0.9'}), isNull);
    });
    test('发布说明摘要截断 500 字', () {
      expect(summarizeNotes('x' * 600).length, 501); // 500 + 省略号
      expect(summarizeNotes('  hi  '), 'hi');
    });
  });
}
