import 'dart:ui';

/// Tool used after the initial screenshot region has been committed.
enum CaptureTool { selection, rectangle, arrow }

/// A simple annotation represented in the capture overlay's logical pixels.
///
/// Rectangles use [start] and [end] as opposite corners. Arrows use them as
/// the start and end points, so the drag direction is preserved.
final class ScreenshotAnnotation {
  const ScreenshotAnnotation({
    required this.tool,
    required this.start,
    required this.end,
    required this.color,
  });

  final CaptureTool tool;
  final Offset start;
  final Offset end;
  final Color color;

  Rect get rect => Rect.fromPoints(start, end);

  ScreenshotAnnotation translatedAndScaled({
    required Offset origin,
    required double scale,
  }) {
    Offset map(Offset point) {
      return Offset(
        (point.dx - origin.dx) / scale,
        (point.dy - origin.dy) / scale,
      );
    }

    return ScreenshotAnnotation(
      tool: tool,
      start: map(start),
      end: map(end),
      color: color,
    );
  }
}

const annotationColors = <Color>[
  Color(0xFFE53935), // red
  Color(0xFF8E44AD), // purple
  Color(0xFFFBC02D), // yellow
  Color(0xFF2E9B59), // green
  Color(0xFFF57C00), // orange
];
