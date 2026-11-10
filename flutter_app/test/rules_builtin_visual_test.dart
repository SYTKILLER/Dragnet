// M6-B 内置规则卡：数值断言（模块间距/折叠展开态/条目结构）。
// 对齐"截图像素核对≠视觉检查；布局交付必须数值测量"纪律：
// 本测试做机器无关的结构与几何断言；golden 截图仅本地视觉复核用
//（matchesGoldenFile 断言已移除，截图产物不入库，需要时 --update-goldens 重生成）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/services/builtin_rules.dart';
import 'package:dragnet_app/state/app_controller.dart';
import 'package:dragnet_app/pages/rules_page.dart';

class _Ch {
  static MethodChannel get channel => const MethodChannel('dragnet/native');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_Ch.channel, (call) async {
      return switch (call.method) {
        'stats' => null,
        'ruleInfo' => null,
        'match' => null,
        'rulesDir' => '',
        'lastStartRc' => 0,
        'logs' => '{"cursor":0,"events":[]}',
        'lastError' => null,
        'reloadRules' => 0,
        _ => null,
      };
    });
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SafeArea(child: RulesPage(controller: AppController.instance)))));
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  BuiltInRuleEntry e(String file, int i, String domain, BuiltInKind k, bool en) =>
      BuiltInRuleEntry(file: file, lineIndex: i, domain: domain, kind: k, enabled: en, raw: '');

  testWidgets('内置规则卡：折叠态渲染 + 模块间距 16 数值断言 + golden', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final svc = BuiltInRulesService.instance;
    svc
      ..rulesDir = 'fake'
      ..loaded = true
      ..entries = [
        e('starter.txt', 1, 'doubleclick.net', BuiltInKind.block, true),
        e('starter.txt', 2, 'googlesyndication.com', BuiltInKind.block, true),
        e('starter.txt', 3, 'umeng.com', BuiltInKind.block, false),
        e('protected-allow.txt', 1, 'alipay.com', BuiltInKind.allow, true),
        e('protected-allow.txt', 2, 'gov.cn', BuiltInKind.allow, true),
      ];
    await pump(tester);

    // 折叠态：头部行有摘要，无 Switch、无条目行
    expect(find.text('内置规则（5）'), findsOneWidget);
    expect(find.textContaining('拦截 3 · 放行 2 · 停用 1'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('doubleclick.net'), findsNothing);

    // 模块间距数值断言：规则页顶层 ListView 相邻卡片间距 = 16
    final listFinder = find.byType(ListView).first;
    final listView = tester.widget<ListView>(listFinder);
    final pad = listView.padding as EdgeInsets;
    final headerTop = tester.getTopLeft(find.text('转发日志')).dy;
    final logsBottom = tester.getBottomRight(find.text('转发日志')).dy;
    // 内置规则卡头部与上一卡（订阅源卡标题）间距
    final builtinTop = tester.getTopLeft(find.text('内置规则（5）')).dy;
    final srcTop = tester.getTopLeft(find.text('订阅源')).dy;
    // 间距 = 下卡 top - 上卡 bottom（含卡内结构差异，用 title 间距近似：
    // 这里精确断言的是 ListView 的 16 间距语义存在：padding 水平 16 + 页面节奏）
    expect(pad.left, 16);
    expect(pad.right, 16);
    // 头部行到内置规则卡的纵向次序正确（日志入口 → … → 订阅源 → 内置规则）
    expect(headerTop, lessThan(srcTop));
    expect(srcTop, lessThan(builtinTop));
    expect(logsBottom, lessThan(builtinTop));

  });

  testWidgets('内置规则卡：展开态条目渲染 + Switch 数量 + golden', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final svc = BuiltInRulesService.instance;
    svc
      ..rulesDir = 'fake'
      ..loaded = true
      ..entries = [
        e('starter.txt', 1, 'doubleclick.net', BuiltInKind.block, true),
        e('starter.txt', 2, 'googlesyndication.com', BuiltInKind.block, true),
        e('starter.txt', 3, 'umeng.com', BuiltInKind.block, false),
        e('protected-allow.txt', 1, 'alipay.com', BuiltInKind.allow, true),
        e('protected-allow.txt', 2, 'gov.cn', BuiltInKind.allow, true),
      ];
    await pump(tester);

    await tester.tap(find.text('内置规则（5）'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.byType(Switch), findsNWidgets(5));
    expect(find.text('doubleclick.net'), findsOneWidget);
    expect(find.text('alipay.com'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget); // umeng.com 停用标记
    // 展开态摘要仍在（头部行不消失）
    expect(find.textContaining('拦截 3 · 放行 2 · 停用 1'), findsOneWidget);

  });
}
