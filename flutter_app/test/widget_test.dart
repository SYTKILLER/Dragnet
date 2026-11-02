// 冒烟测试：mock 原生通道（无插件实现），验证液态玻璃壳与四 Tab 渲染。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dragnet_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 无原生实现环境（flutter test）：所有通道调用返回空值
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppControllerPrivate.channel, (call) async {
      return switch (call.method) {
        'stats' => null,
        'ruleInfo' => null,
        'rulesDir' => '/data/user/0/com.march.dragnet_app/files/rules',
        // 方向1 新增三方法：日志空环 / 无启动失败 / 重载成功
        'logs' => '{"cursor":0,"events":[]}',
        'lastError' => null,
        'reloadRules' => 0,
        _ => null,
      };
    });
  });

  testWidgets('应用壳渲染 + 四 Tab 内容切换', (tester) async {
    await tester.pumpWidget(const DragnetApp());
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 仪表盘状态卡
    expect(find.text('罗网 Dragnet'), findsWidgets);
    expect(find.text('拦截已停止'), findsOneWidget);

    // 切到统计 Tab
    await tester.tap(find.text('统计').last);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('内核未运行'), findsOneWidget);

    // 切到设置 Tab
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('玻璃质感'), findsOneWidget);
  });
}

/// 测试钩子：暴露 channel 给 mock 用（避免污染公开 API）。
class AppControllerPrivate {
  static MethodChannel get channel =>
      const MethodChannel('dragnet/native');
}
