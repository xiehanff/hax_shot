import 'package:hax_shot/features/capture/capture_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';

void main() {
  testWidgets('toolbar paints its controls and handles actions', (
    tester,
  ) async {
    var cancelled = false;
    var saved = false;
    var copied = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CaptureToolbar(
              enabled: true,
              busy: false,
              onCancel: () => cancelled = true,
              onSave: () => saved = true,
              onCopy: () => copied = true,
            ),
          ),
        ),
      ),
    );

    // A decoration paint failure can hide every control despite a valid layout.
    expect(tester.takeException(), isNull);
    expect(find.byType(HugeIcon), findsNWidgets(10));
    await tester.tap(find.byTooltip('取消 (Esc)'));
    await tester.tap(find.byTooltip('保存 PNG'));
    await tester.tap(find.byTooltip('复制到剪贴板'));
    expect(cancelled, isTrue);
    expect(saved, isTrue);
    expect(copied, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
