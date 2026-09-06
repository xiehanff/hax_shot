import 'dart:ui' as ui;

import 'package:hax_shot/features/capture/annotation.dart';
import 'package:hax_shot/features/capture/screenshot_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps logical selection coordinates to image pixels', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 200, 100),
      Paint()..color = Colors.blue,
    );
    final image = await recorder.endRecording().toImage(200, 100);

    final layout = ScreenshotLayout.fromViewport(const Size(1000, 500), image);
    final pixelRect = layout.toPixelRect(
      const Rect.fromLTWH(100, 50, 200, 100),
    );

    expect(layout.imageRect, const Rect.fromLTWH(0, 0, 1000, 500));
    expect(pixelRect, const Rect.fromLTWH(20, 10, 40, 20));
    image.dispose();
  });

  testWidgets('paints rectangle and arrow annotations in the selection', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 200, 100),
      Paint()..color = Colors.blue,
    );
    final image = await recorder.endRecording().toImage(200, 100);
    final layout = ScreenshotLayout(
      imageRect: const Rect.fromLTWH(0, 0, 200, 100),
      imageSize: const Size(200, 100),
      scale: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: ScreenshotCanvas(
            image: image,
            layout: layout,
            selection: const Rect.fromLTWH(10, 10, 180, 80),
            annotations: const [
              ScreenshotAnnotation(
                tool: CaptureTool.rectangle,
                start: Offset(20, 20),
                end: Offset(80, 60),
                color: Colors.red,
              ),
              ScreenshotAnnotation(
                tool: CaptureTool.arrow,
                start: Offset(90, 70),
                end: Offset(160, 30),
                color: Colors.green,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    image.dispose();
  });
}
