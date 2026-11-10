// M6 出站 DNS 上游卡（对齐鸿蒙设置页）：结构断言 + 保存校验闭环
//（非法拒保存 / 合法保存落提示）。文件面在测试环境为 no-op（非 Android）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/pages/settings_page.dart';
import 'package:dragnet_app/services/rule_source.dart';
import 'package:dragnet_app/state/app_controller.dart';

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

  testWidgets('DNS 上游卡：三预置 + 自定义输入 + 非法拒绝 / 合法保存', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SafeArea(
                child: SettingsPage(controller: AppController.instance)))));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // 结构：标题 + 三预置 chip + 自定义输入框 + 保存钮
    expect(find.text('出站 DNS 上游'), findsOneWidget);
    expect(find.text('阿里'), findsOneWidget);
    expect(find.text('腾讯'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    // 初始值 = 默认 223.5.5.5:53（读文件 no-op → defaultDnsUp）
    expect(find.text('223.5.5.5:53'), findsWidgets);
    expect(find.textContaining('当前值非法'), findsNothing);

    // 非法输入 → 保存被拒（错误 snackbar，无"已保存"）；
    // 卡片在长列表视口外，tap 前必须滚到可见（hit-test 才能命中）
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'abc');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('格式需为 ip:port'), findsOneWidget);
    expect(find.textContaining('已保存'), findsNothing);

    // 合法输入 → 保存提示（写盘 no-op 但流程走通）
    await tester.enterText(find.byType(TextField).last, '114.114.114.114:53');
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('已保存 114.114.114.114:53'), findsOneWidget);
  });

  test('isValidIpPort 纯函数已被 rule_source_test 覆盖（哨兵）', () {
    expect(isValidIpPort('1.1.1.1:53'), true);
  });
}
