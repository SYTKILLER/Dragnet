// M6-B 内置规则纯函数单测：行解析（含停用形态）、注释/停用规则区分、
// toggle 翻转往返无损、越界/注释行拒绝。

import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/services/builtin_rules.dart';

void main() {
  group('parseBuiltInRuleLine', () {
    test('拦截/放行启用形态', () {
      final b = parseBuiltInRuleLine('starter.txt', 3, '||doubleclick.net^');
      expect(b, isNotNull);
      expect(b!.kind, BuiltInKind.block);
      expect(b.enabled, true);
      expect(b.domain, 'doubleclick.net');
      final a = parseBuiltInRuleLine(
          'protected-allow.txt', 6, '@@||alipay.com^\$important');
      expect(a!.kind, BuiltInKind.allow);
      expect(a.enabled, true);
      expect(a.domain, 'alipay.com');
    });
    test('停用形态 = "! " 前缀（对齐鸿蒙 encodeRuleLine）', () {
      final b = parseBuiltInRuleLine('starter.txt', 4, '! ||doubleclick.net^');
      expect(b!.enabled, false);
      expect(b.kind, BuiltInKind.block);
      expect(b.domain, 'doubleclick.net');
      final a = parseBuiltInRuleLine(
          'protected-allow.txt', 7, '! @@||tenpay.com^\$important');
      expect(a!.enabled, false);
      expect(a.kind, BuiltInKind.allow);
    });
    test('普通注释行/空行/垃圾行 → null（不得误判为停用规则）', () {
      expect(parseBuiltInRuleLine('starter.txt', 0, '! 罗网 Dragnet 种子规则'), isNull);
      expect(parseBuiltInRuleLine('starter.txt', 1, ''), isNull);
      expect(parseBuiltInRuleLine('starter.txt', 2, '!'), isNull);
      expect(parseBuiltInRuleLine('starter.txt', 5, '不是规则行'), isNull);
    });
  });

  group('parseBuiltInRules + toggleBuiltInLine', () {
    const sample = '! 头注释\n||doubleclick.net^\n! ||umeng.com^\n'
        '\n@@||alipay.com^\$important\n! 尾注释';
    test('解析保留行序与 lineIndex，停用规则入列', () {
      final es = parseBuiltInRules('starter.txt', sample);
      expect(es, hasLength(3));
      expect(es[0].lineIndex, 1);
      expect(es[0].domain, 'doubleclick.net');
      expect(es[1].lineIndex, 2);
      expect(es[1].enabled, false);
      expect(es[2].lineIndex, 4);
      expect(es[2].kind, BuiltInKind.allow);
    });
    test('toggle 启→停→启 往返无损，注释/空行原样保留', () {
      final off = toggleBuiltInLine(sample, 1);
      expect(off, isNotNull);
      expect(off!.split('\n')[1], '! ||doubleclick.net^');
      final back = toggleBuiltInLine(off, 1);
      expect(back!.split('\n')[1], '||doubleclick.net^');
      // 其余行（含停用行/注释/空行）原样
      expect(back.split('\n')[0], '! 头注释');
      expect(back.split('\n')[2], '! ||umeng.com^');
      expect(back.split('\n')[4], '@@||alipay.com^\$important');
      final es = parseBuiltInRules('starter.txt', back);
      expect(es.where((e) => e.enabled), hasLength(2));
      expect(es.where((e) => !e.enabled), hasLength(1));
    });
    test('toggle 停→启（写回种子本身的停用规则可恢复）', () {
      final on = toggleBuiltInLine(sample, 2);
      expect(on!.split('\n')[2], '||umeng.com^');
    });
    test('越界/注释行 toggle 拒绝', () {
      expect(toggleBuiltInLine(sample, -1), isNull);
      expect(toggleBuiltInLine(sample, 99), isNull);
      expect(toggleBuiltInLine(sample, 0), isNull); // 头注释
      expect(toggleBuiltInLine(sample, 3), isNull); // 空行
    });
  });
}
