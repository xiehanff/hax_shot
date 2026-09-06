import 'dart:ui';

import 'annotation.dart';
import 'screenshot_canvas.dart';

/// Owns the mutable interaction state for one capture editing session.
///
/// The widget layer remains responsible for repainting, focus and async window
/// work. This class keeps selection/drawing transitions in one place so pointer
/// handlers do not need to repeatedly infer the active gesture mode.
final class CaptureSession {
  CaptureTool activeTool = CaptureTool.selection;
  Color selectedColor = annotationColors.first;
  Rect? selection;
  bool selectionCommitted = false;
  ScreenshotAnnotation? draftAnnotation;

  Offset? _dragStart;
  List<ScreenshotAnnotation> _annotations = const [];

  List<ScreenshotAnnotation> get annotations => _annotations;

  bool get isTextTool => activeTool == CaptureTool.text;

  bool get hasCommittedSelection =>
      selectionCommitted && selection != null;

  void selectTool(CaptureTool tool) {
    activeTool = tool;
    _dragStart = null;
    draftAnnotation = null;
  }

  void selectColor(Color color) {
    selectedColor = color;
  }

  void startGesture(ScreenshotLayout layout, Offset point) {
    if (isTextTool) return;
    if (activeTool == CaptureTool.selection || selection == null) {
      _startSelection(layout, point);
      return;
    }
    _startAnnotation(layout, point);
  }

  void updateGesture(ScreenshotLayout layout, Offset point) {
    if (isTextTool) return;
    if (activeTool == CaptureTool.selection || selection == null) {
      _updateSelection(layout, point);
      return;
    }
    _updateAnnotation(layout, point);
  }

  /// Completes the current gesture and returns a user-facing validation message
  /// when the gesture is too small to commit.
  String? finishGesture() {
    if (isTextTool) return null;
    if (activeTool == CaptureTool.selection || selection == null) {
      return _finishSelection();
    }
    return _finishAnnotation();
  }

  Offset clampToSelection(ScreenshotLayout layout, Offset point) {
    final selected = selection;
    if (selected == null) return layout.clampToImage(point);
    final clampedToImage = layout.clampToImage(point);
    return Offset(
      clampedToImage.dx.clamp(selected.left, selected.right).toDouble(),
      clampedToImage.dy.clamp(selected.top, selected.bottom).toDouble(),
    );
  }

  ScreenshotAnnotation? takeTextAnnotationAt(Offset point) {
    for (var index = _annotations.length - 1; index >= 0; index--) {
      final annotation = _annotations[index];
      if (annotation.tool == CaptureTool.text &&
          annotation.text.isNotEmpty &&
          annotation.rect.contains(point)) {
        final remaining = [..._annotations]..removeAt(index);
        _annotations = remaining;
        return annotation;
      }
    }
    return null;
  }

  void addAnnotation(ScreenshotAnnotation annotation) {
    _annotations = [..._annotations, annotation];
  }

  void _startSelection(ScreenshotLayout layout, Offset point) {
    final start = layout.clampToImage(point);
    _dragStart = start;
    selection = null;
    selectionCommitted = false;
    activeTool = CaptureTool.selection;
    _annotations = const [];
    draftAnnotation = null;
  }

  void _updateSelection(ScreenshotLayout layout, Offset point) {
    final start = _dragStart;
    if (start == null) return;
    final current = layout.clampToImage(point);
    selection = Rect.fromPoints(start, current);
    selectionCommitted = false;
  }

  String? _finishSelection() {
    final selected = selection;
    _dragStart = null;
    if (selected == null || selected.width < 4 || selected.height < 4) {
      selection = null;
      selectionCommitted = false;
      return '请拖动选择一个更大的区域';
    }

    activeTool = CaptureTool.selection;
    selectionCommitted = true;
    return null;
  }

  void _startAnnotation(ScreenshotLayout layout, Offset point) {
    if (!hasCommittedSelection) return;
    final start = clampToSelection(layout, point);
    _dragStart = start;
    draftAnnotation = ScreenshotAnnotation(
      tool: activeTool,
      start: start,
      end: start,
      color: selectedColor,
    );
  }

  void _updateAnnotation(ScreenshotLayout layout, Offset point) {
    final start = _dragStart;
    if (start == null || activeTool == CaptureTool.selection) return;
    final current = clampToSelection(layout, point);
    draftAnnotation = ScreenshotAnnotation(
      tool: activeTool,
      start: start,
      end: current,
      color: selectedColor,
    );
  }

  String? _finishAnnotation() {
    final draft = draftAnnotation;
    _dragStart = null;
    draftAnnotation = null;
    final isLargeEnough = draft == null
        ? false
        : draft.tool == CaptureTool.arrow
        ? (draft.end - draft.start).distance >= 4
        : draft.rect.shortestSide >= 4;
    if (!isLargeEnough) {
      return '请拖动绘制一个更大的标注';
    }
    addAnnotation(draft);
    return null;
  }
}
