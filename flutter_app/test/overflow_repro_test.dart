// M6-B 溢出复现：353 逻辑宽（=模拟器 1080/3.05）下仪表盘 RenderFlex overflow。
// 修复后此测试应零异常通过（保留作回归哨兵）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/main.dart';

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

  testWidgets('仪表盘 353 宽无溢出', (tester) async {
    tester.view.physicalSize = const Size(1077, 1920);
    tester.view.devicePixelRatio = 3.048;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DragnetApp());
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('拦截已停止'), findsOneWidget);
  });
}
