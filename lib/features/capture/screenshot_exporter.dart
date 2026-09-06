import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'annotation.dart';
import 'screenshot_canvas.dart';

/// Renders a committed selection and its annotations into PNG bytes.
final class ScreenshotExporter {
  const ScreenshotExporter._();

  static Future<Uint8List> renderPng({
    required ui.Image image,
    required ScreenshotLayout layout,
    required Rect selection,
    required List<ScreenshotAnnotation> annotations,
  }) async {
    final source = layout.toPixelRect(selection);
    final width = source.width.round().clamp(1, image.width);
    final height = source.height.round().clamp(1, image.height);
    final destination = Rect.fromLTWH(
      0,
      0,
      width.toDouble(),
      height.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        source.left,
        source.top,
        width.toDouble(),
        height.toDouble(),
      ),
      destination,
      Paint()..filterQuality = FilterQuality.high,
    );

    final cropOrigin = Offset(
      layout.imageRect.left + source.left * layout.scale,
      layout.imageRect.top + source.top * layout.scale,
    );
    canvas.save();
    canvas.clipRect(destination);
    for (final annotation in annotations) {
      final pixelAnnotation = annotation.translatedAndScaled(
        origin: cropOrigin,
        scale: layout.scale,
      );
      paintScreenshotAnnotation(
        canvas,
        pixelAnnotation,
        lineWidth: 3 / layout.scale,
        arrowHeadLength: 14 / layout.scale,
      );
    }
    canvas.restore();

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(width, height);
    picture.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (data == null) {
      throw StateError('PNG 编码失败');
    }
    return data.buffer.asUint8List();
  }
}
