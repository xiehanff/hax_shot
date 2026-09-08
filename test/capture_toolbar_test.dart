import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/capture/annotation.dart';
import 'package:hax_shot/features/capture/capture_toolbar.dart';
import 'package:hugeicons/hugeicons.dart';

void main() {
  testWidgets('toolbar paints its controls and handles actions', (
    tester,
  ) async {
    var cancelled = false;
    var saved = false;
    var copied = false;
    CaptureTool? selectedTool;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CaptureToolbar(
              busy: false,
              activeTool: CaptureTool.selection,
              selectedColor: annotationColors.first,
              onToolSelected: (tool) => selectedTool = tool,
              onColorSelected: (_) {},
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
    await tester.tap(find.byTooltip('标注矩形'));
    expect(selectedTool, CaptureTool.rectangle);
    await tester.tap(find.byTooltip('标注文字'));
    expect(selectedTool, CaptureTool.text);
    await tester.tap(find.byTooltip('标注箭头'));
    expect(selectedTool, CaptureTool.arrow);
    await tester.tap(find.byTooltip('取消 (Esc)'));
    await tester.tap(find.byTooltip('保存 PNG'));
    await tester.tap(find.byTooltip('复制到剪贴板'));
    expect(cancelled, isTrue);
    expect(saved, isTrue);
    expect(copied, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI actions invoke callbacks and are disabled while busy', (
    tester,
  ) async {
    var translated = false;
    var explained = false;
    var deeplyUnderstood = false;

    Widget buildToolbar({required bool busy}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: CaptureToolbar(
              busy: busy,
              activeTool: CaptureTool.selection,
              selectedColor: annotationColors.first,
              onToolSelected: (_) {},
              onColorSelected: (_) {},
              onCancel: () {},
              onSave: () {},
              onCopy: () {},
              onTranslate: () => translated = true,
              onExplain: () => explained = true,
              onDeepUnderstand: () => deeplyUnderstood = true,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildToolbar(busy: false));
    await tester.tap(find.byTooltip('翻译截图'));
    await tester.tap(find.byTooltip('解释截图'));
    await tester.tap(find.byTooltip('深入理解截图'));
    expect(translated, isTrue);
    expect(explained, isTrue);
    expect(deeplyUnderstood, isTrue);

    translated = false;
    explained = false;
    deeplyUnderstood = false;
    await tester.pumpWidget(buildToolbar(busy: true));
    await tester.tap(find.byTooltip('翻译截图'));
    await tester.tap(find.byTooltip('解释截图'));
    await tester.tap(find.byTooltip('深入理解截图'));
    expect(translated, isFalse);
    expect(explained, isFalse);
    expect(deeplyUnderstood, isFalse);
  });
}
