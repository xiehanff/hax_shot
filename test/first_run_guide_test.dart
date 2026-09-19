import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/onboarding/first_run_guide.dart';

void main() {
  Future<void> pumpGuide(WidgetTester tester, {String shortcutLabel = '⌥+Z'}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Center(
          child: SizedBox(
            width: 560,
            height: 400,
            child: FirstRunGuide(
              shortcutLabel: shortcutLabel,
              onOpenSettings: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('欢迎页说明图标位置、快捷键和首次授权', (tester) async {
    await pumpGuide(tester);

    // 只有 macOS 会提屏幕录制授权（Windows / Linux 提权限只会让人去找一个不存在的开关），
    // 所以这句文案本身就是平台分支的，断言也要跟着分支（否则 Linux 上必然找不到）。
    final expectedShortcutDetail = Platform.isMacOS
        ? '首次截图时 macOS 会要求屏幕录制权限'
        : '按下快捷键即可开始截图';

    expect(find.text('HaxShot 已在后台运行'), findsOneWidget);
    expect(find.textContaining('截图快捷键：⌥+Z'), findsOneWidget);
    expect(find.textContaining(expectedShortcutDetail), findsOneWidget);
    expect(find.text('打开设置'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
  });

  testWidgets('没设置快捷键时显示未设置，而不是空白', (tester) async {
    await pumpGuide(tester, shortcutLabel: '');
    expect(find.textContaining('截图快捷键：未设置'), findsOneWidget);
  });

  testWidgets('关闭按钮在标题栏右上角', (tester) async {
    await pumpGuide(tester);

    final box = tester.getRect(find.byType(FirstRunGuide));
    final close = tester.getRect(find.byIcon(Icons.close));
    expect(box.right - close.right, lessThan(40));
    expect(close.top - box.top, lessThan(60));
  });
}
