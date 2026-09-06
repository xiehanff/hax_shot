import 'dart:ui' as ui;

import 'package:easy_shot/features/capture/screenshot_canvas.dart';
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
}
