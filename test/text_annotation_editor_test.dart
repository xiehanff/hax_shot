import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:hax_shot/features/capture/annotation.dart';
import 'package:hax_shot/features/capture/text_annotation_editor.dart';

void main() {
  testWidgets('shows text input and four resize handles', (tester) async {
    final controller = TextEditingController(text: 'A');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    final resizeDeltas = <Offset>[];
    final moveDeltas = <Offset>[];
    var deleted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 120,
            child: TextAnnotationEditor(
              annotation: const ScreenshotAnnotation(
                tool: CaptureTool.text,
                start: Offset(20, 20),
                end: Offset(120, 60),
                color: Colors.red,
                text: 'A',
                fontSize: 24,
              ),
              controller: controller,
              focusNode: focusNode,
              onResizeStart: (_) {},
              onResizeUpdate: (_, delta) => resizeDeltas.add(delta),
              onResizeEnd: (_) {},
              onMoveStart: () {},
              onMoveUpdate: moveDeltas.add,
              onMoveEnd: () {},
              onDelete: () => deleted = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(HugeIcon), findsNWidgets(2));
    for (final handle in TextResizeHandle.values) {
      expect(
        find.byKey(ValueKey('text-resize-${handle.name}')),
        findsOneWidget,
      );
    }

    await tester.drag(
      find.byKey(const ValueKey('text-resize-bottomRight')),
      const Offset(20, 10),
    );
    expect(resizeDeltas, isNotEmpty);

    await tester.drag(
      find.byKey(const ValueKey('text-move-handle')),
      const Offset(12, 8),
    );
    expect(moveDeltas, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('text-delete-button')));
    expect(deleted, isTrue);
  });
}
