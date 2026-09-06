import 'dart:ui';

/// Tool used after the initial screenshot region has been committed.
enum CaptureTool { selection, rectangle, arrow, text }

/// Which corner of a text annotation is being resized.
enum TextResizeHandle { topLeft, topRight, bottomLeft, bottomRight }

/// A simple annotation represented in the capture overlay's logical pixels.
///
/// Rectangles use [start] and [end] as opposite corners. Arrows use them as
/// the start and end points, so the drag direction is preserved. Text uses
/// them as the top-left and bottom-right corners of its text box.
final class ScreenshotAnnotation {
  const ScreenshotAnnotation({
    required this.tool,
    required this.start,
    required this.end,
    required this.color,
    this.text = '',
    this.fontSize = 24,
  });

  final CaptureTool tool;
  final Offset start;
  final Offset end;
  final Color color;
  final String text;
  final double fontSize;

  Rect get rect => Rect.fromPoints(start, end);

  ScreenshotAnnotation copyWith({
    Offset? start,
    Offset? end,
    Color? color,
    String? text,
    double? fontSize,
  }) {
    return ScreenshotAnnotation(
      tool: tool,
      start: start ?? this.start,
      end: end ?? this.end,
      color: color ?? this.color,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
    );
  }

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
      text: text,
      fontSize: fontSize / scale,
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
