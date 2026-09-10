import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/capture/capture_permission_guide.dart';

void main() {
  Future<void> pumpGuide(
    WidgetTester tester, {
    Size size = const Size(560, 400),
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: CapturePermissionGuide(onRetry: () async {}, onQuit: () {}),
          ),
        ),
      ),
    );
  }

  testWidgets('关闭按钮在窗口右上角，且没有重复的退出按钮', (tester) async {
    const size = Size(560, 400);
    await pumpGuide(tester);

    // 以引导页自身占据的矩形为基准算相对位置。
    final box = tester.getRect(find.byType(CapturePermissionGuide));
    final close = find.byIcon(Icons.close);
    expect(close, findsOneWidget);

    final closeRect = tester.getRect(close);
    // 距离窗口右边缘 / 上边缘都很近，才算“右上角”。
    expect(box.right - closeRect.right, lessThan(40));
    expect(closeRect.top - box.top, lessThan(60));
    // 引导页只保留“打开系统设置 / 我已授权，重新检查”，退出靠右上角 ✕。
    expect(find.text('退出'), findsNothing);
    expect(find.text('打开系统设置'), findsOneWidget);
    expect(find.text('我已授权，重新检查'), findsOneWidget);
  });

  testWidgets('内容从顶部开始排布，窗口不会被撑高', (tester) async {
    await pumpGuide(tester);

    final box = tester.getRect(find.byType(CapturePermissionGuide));
    final title = tester.getRect(find.text('需要屏幕录制权限'));
    // 标题贴着顶部（内容垂直居中时会落到窗口 1/3 高度处）。
    expect(title.top - box.top, lessThan(45));

    // 内容整体不超出窗口高度，窗口也不必再留一大截空白。
    final buttons = tester.getRect(find.text('打开系统设置'));
    expect(buttons.bottom, lessThan(box.bottom));
    expect(box.height, 400);
  });

  testWidgets('没有授权信息时显示引导文案', (tester) async {
    await pumpGuide(tester);
    expect(find.textContaining('屏幕录制'), findsWidgets);
    expect(find.textContaining('1. 点下面'), findsOneWidget);
  });
}
