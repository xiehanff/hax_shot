import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/capture/annotation.dart';
import 'package:hax_shot/features/capture/capture_session.dart';
import 'package:hax_shot/features/capture/screenshot_canvas.dart';

void main() {
  const layout = ScreenshotLayout(
    imageRect: Rect.fromLTWH(0, 0, 800, 600),
    imageSize: Size(800, 600),
    scale: 1,
  );

  test('owns selection and annotation gesture transitions', () {
    final session = CaptureSession();

    session.startGesture(layout, const Offset(20, 30));
    session.updateGesture(layout, const Offset(220, 180));
    expect(session.finishGesture(), isNull);
    expect(session.selection, const Rect.fromLTRB(20, 30, 220, 180));
    expect(session.hasCommittedSelection, isTrue);

    session.selectTool(CaptureTool.rectangle);
    session.startGesture(layout, const Offset(40, 50));
    session.updateGesture(layout, const Offset(120, 110));
    expect(session.finishGesture(), isNull);
    expect(session.annotations, hasLength(1));
    expect(session.annotations.single.tool, CaptureTool.rectangle);
  });

  test('starting a new selection clears old annotations', () {
    final session = CaptureSession();
    session.startGesture(layout, const Offset(10, 10));
    session.updateGesture(layout, const Offset(300, 200));
    session.finishGesture();
    session.addAnnotation(
      const ScreenshotAnnotation(
        tool: CaptureTool.rectangle,
        start: Offset(20, 20),
        end: Offset(80, 80),
        color: Color(0xFFE53935),
      ),
    );

    session.selectTool(CaptureTool.selection);
    session.startGesture(layout, const Offset(100, 100));

    expect(session.annotations, isEmpty);
    expect(session.selectionCommitted, isFalse);
  });

  test('rejects tiny gestures and can reopen text annotations', () {
    final session = CaptureSession();
    session.startGesture(layout, const Offset(10, 10));
    session.updateGesture(layout, const Offset(12, 12));
    expect(session.finishGesture(), isNotNull);
    expect(session.selection, isNull);

    session.startGesture(layout, const Offset(10, 10));
    session.updateGesture(layout, const Offset(300, 200));
    session.finishGesture();
    session.addAnnotation(
      const ScreenshotAnnotation(
        tool: CaptureTool.text,
        start: Offset(40, 50),
        end: Offset(160, 90),
        color: Color(0xFF2E9B59),
        text: 'hello',
      ),
    );

    final reopened = session.takeTextAnnotationAt(const Offset(80, 70));
    expect(reopened?.text, 'hello');
    expect(session.annotations, isEmpty);
  });
}
