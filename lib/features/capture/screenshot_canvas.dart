import 'dart:ui' as ui;

import 'package:flutter/material.dart';

final class ScreenshotLayout {
  const ScreenshotLayout({
    required this.imageRect,
    required this.imageSize,
    required this.scale,
  });

  final Rect imageRect;
  final Size imageSize;
  final double scale;

  factory ScreenshotLayout.fromViewport(Size viewport, ui.Image image) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final scale = _fitScale(viewport, imageSize);
    final drawnSize = imageSize * scale;
    final offset = Offset(
      (viewport.width - drawnSize.width) / 2,
      (viewport.height - drawnSize.height) / 2,
    );

    return ScreenshotLayout(
      imageRect: offset & drawnSize,
      imageSize: imageSize,
      scale: scale,
    );
  }

  Offset clampToImage(Offset point) {
    return Offset(
      point.dx.clamp(imageRect.left, imageRect.right).toDouble(),
      point.dy.clamp(imageRect.top, imageRect.bottom).toDouble(),
    );
  }

  Rect toPixelRect(Rect logicalRect) {
    final clipped = logicalRect.intersect(imageRect);
    final left = ((clipped.left - imageRect.left) / scale).floor().clamp(
      0,
      imageSize.width.toInt(),
    );
    final top = ((clipped.top - imageRect.top) / scale).floor().clamp(
      0,
      imageSize.height.toInt(),
    );
    final right = ((clipped.right - imageRect.left) / scale).ceil().clamp(
      left + 1,
      imageSize.width.toInt(),
    );
    final bottom = ((clipped.bottom - imageRect.top) / scale).ceil().clamp(
      top + 1,
      imageSize.height.toInt(),
    );

    return Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
  }

  static double _fitScale(Size viewport, Size image) {
    if (viewport.isEmpty || image.isEmpty) {
      return 1;
    }
    return (viewport.width / image.width).clamp(
      0,
      viewport.height / image.height,
    );
  }
}

class ScreenshotCanvas extends StatelessWidget {
  const ScreenshotCanvas({
    required this.image,
    required this.layout,
    required this.selection,
    super.key,
  });

  final ui.Image image;
  final ScreenshotLayout layout;
  final Rect? selection;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScreenshotPainter(
        image: image,
        layout: layout,
        selection: selection,
      ),
      size: Size.infinite,
    );
  }
}

final class _ScreenshotPainter extends CustomPainter {
  _ScreenshotPainter({
    required this.image,
    required this.layout,
    required this.selection,
  });

  final ui.Image image;
  final ScreenshotLayout layout;
  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.black, BlendMode.src);

    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final paint = Paint()..filterQuality = FilterQuality.high;
    canvas.drawImageRect(image, source, layout.imageRect, paint);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.58),
    );

    final selected = selection;
    if (selected == null) {
      return;
    }

    canvas.save();
    canvas.clipRect(selected);
    canvas.drawImageRect(image, source, layout.imageRect, paint);
    canvas.restore();

    canvas.drawRect(
      selected,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final label =
        '${(selected.width / layout.scale).round()} × '
        '${(selected.height / layout.scale).round()}';
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelRect = Rect.fromLTWH(
      selected.left,
      (selected.top - textPainter.height - 8).clamp(8, size.height),
      textPainter.width + 12,
      textPainter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.8),
    );
    textPainter.paint(canvas, labelRect.topLeft + const Offset(6, 2));
  }

  @override
  bool shouldRepaint(covariant _ScreenshotPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.layout != layout ||
        oldDelegate.selection != selection;
  }
}
