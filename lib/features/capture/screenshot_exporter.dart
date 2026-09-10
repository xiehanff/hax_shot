import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../native/native_bridge.dart';
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

    // 像素交给 Rust 编码：Skia 的 toByteData(png) 是 zlib level 6，一张
    // 3024x1964 的选区要几百毫秒；原生侧 fdeflate 只要几十毫秒（体积约 +20%）。
    // rawStraightRgba 是非预乘的 RGBA，正好是 PNG 需要的格式。
    final raw = await cropped.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    cropped.dispose();
    if (raw == null) {
      throw StateError('读取截图像素失败');
    }
    return NativeBridge.instance.encodePng(
      raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
      width,
      height,
    );
  }
}
