import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../native/native_bridge.dart';
import 'annotation.dart';
import 'capture_toolbar.dart';
import 'screenshot_canvas.dart';
import 'selection_toolbar_placement.dart';
import 'text_annotation_editor.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  ui.Image? _image;
  Offset? _dragStart;
  Rect? _selection;
  String? _message;
  bool _loading = true;
  bool _busy = false;
  bool _selectionCommitted = false;
  CaptureTool _activeTool = CaptureTool.selection;
  Color _selectedColor = annotationColors.first;
  List<ScreenshotAnnotation> _annotations = const [];
  ScreenshotAnnotation? _draftAnnotation;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode(debugLabel: 'capture-text');
  ScreenshotAnnotation? _textDraft;
  bool _textAutoSizing = false;
  bool _suppressTextListener = false;
  ScreenshotAnnotation? _textResizeStart;
  TextResizeHandle? _textResizeHandle;
  Offset _textResizePointer = Offset.zero;
  ScreenshotAnnotation? _textMoveStart;
  Offset _textMoveOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_handleTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void dispose() {
    _textController.removeListener(_handleTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    try {
      final path = await NativeBridge.instance.captureScreen();
      final file = File(path);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      try {
        await file.delete();
      } on Object {
        // The temporary file is safe to leave behind if another process owns it.
      }

      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image = frame.image;
        _loading = false;
        _message = null;
      });
      // Reveal the frozen screenshot only after native capture completes.
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '截图失败：$error';
      });
      await windowManager.show();
      await windowManager.focus();
    }
  }

  void _selectTool(CaptureTool tool) {
    if (_busy || !mounted) return;
    if (_activeTool == CaptureTool.text && tool != CaptureTool.text) {
      _commitTextDraft();
    }
    setState(() {
      _activeTool = tool;
      _dragStart = null;
      _draftAnnotation = null;
      _message = null;
    });
  }

  void _selectColor(Color color) {
    if (!mounted) return;
    setState(() {
      _selectedColor = color;
      final draft = _textDraft;
      if (draft != null) {
        _textDraft = draft.copyWith(color: color);
      }
    });
  }

  Size _measureText(String text, double fontSize, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? 'M' : text,
        style: TextStyle(fontSize: fontSize, height: 1),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: math.max(1, maxWidth));
    return Size(painter.width, painter.height);
  }

  Rect _textRectForInput({
    required Offset requestedStart,
    required String text,
    required double fontSize,
    required Rect bounds,
  }) {
    final measured = _measureText(text, fontSize, bounds.width);
    final width = math.min(
      math.max(measured.width + 4, 24).toDouble(),
      bounds.width,
    );
    final height = math.min(
      math.max(measured.height + 4, fontSize + 8).toDouble(),
      bounds.height,
    );
    final limits = _textPositionLimits(bounds, Size(width, height));
    final left = requestedStart.dx.clamp(limits.left, limits.right);
    final top = requestedStart.dy.clamp(limits.top, limits.bottom);
    return Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  Rect _textPositionLimits(Rect bounds, Size textSize) {
    final canReserveHorizontal =
        bounds.width >=
        textSize.width + TextAnnotationEditor.horizontalInset * 2;
    final minLeft = canReserveHorizontal
        ? bounds.left + TextAnnotationEditor.horizontalInset
        : bounds.left;
    final maxLeft =
        bounds.right -
        textSize.width -
        (canReserveHorizontal ? TextAnnotationEditor.horizontalInset : 0);
    final canReserveTop =
        bounds.height >= textSize.height + TextAnnotationEditor.topInset;
    final minTop = canReserveTop
        ? bounds.top + TextAnnotationEditor.topInset
        : bounds.top;
    final maxTop = bounds.bottom - textSize.height;
    return Rect.fromLTRB(minLeft, minTop, maxLeft, maxTop);
  }

  void _handleTextChanged() {
    if (_suppressTextListener || !mounted) return;
    final draft = _textDraft;
    if (draft == null) return;

    var updated = draft.copyWith(text: _textController.text);
    final selection = _selection;
    if (_textAutoSizing && selection != null) {
      final rect = _textRectForInput(
        requestedStart: draft.start,
        text: _textController.text,
        fontSize: draft.fontSize,
        bounds: selection,
      );
      updated = updated.copyWith(start: rect.topLeft, end: rect.bottomRight);
    }
    setState(() => _textDraft = updated);
  }

  void _beginTextInput(ScreenshotLayout layout, Offset point) {
    final selection = _selection;
    if (selection == null || !_selectionCommitted) return;

    _commitTextDraft();
    final start = _clampToSelection(layout, point);
    final rect = _textRectForInput(
      requestedStart: start,
      text: '',
      fontSize: 24,
      bounds: selection,
    );
    _suppressTextListener = true;
    _textController.clear();
    _suppressTextListener = false;

    setState(() {
      _activeTool = CaptureTool.text;
      _textAutoSizing = true;
      _textDraft = ScreenshotAnnotation(
        tool: CaptureTool.text,
        start: rect.topLeft,
        end: rect.bottomRight,
        color: _selectedColor,
        fontSize: 24,
      );
      _message = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _textDraft == null) return;
      _textFocusNode.requestFocus();
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
  }

  void _commitTextDraft() {
    final draft = _textDraft;
    if (draft == null) return;
    final text = _textController.text;
    final committed = text.isEmpty ? null : draft.copyWith(text: text);
    _suppressTextListener = true;
    _textController.clear();
    _suppressTextListener = false;
    _textFocusNode.unfocus();
    _textResizeStart = null;
    _textResizeHandle = null;
    _textMoveStart = null;
    _textMoveOffset = Offset.zero;
    _textAutoSizing = false;
    if (!mounted) return;
    setState(() {
      _textDraft = null;
      if (committed != null) {
        _annotations = [..._annotations, committed];
      }
    });
  }

  Offset _textCorner(Rect rect, TextResizeHandle handle) {
    return switch (handle) {
      TextResizeHandle.topLeft => rect.topLeft,
      TextResizeHandle.topRight => rect.topRight,
      TextResizeHandle.bottomLeft => rect.bottomLeft,
      TextResizeHandle.bottomRight => rect.bottomRight,
    };
  }

  Offset _textOppositeCorner(Rect rect, TextResizeHandle handle) {
    return switch (handle) {
      TextResizeHandle.topLeft => rect.bottomRight,
      TextResizeHandle.topRight => rect.bottomLeft,
      TextResizeHandle.bottomLeft => rect.topRight,
      TextResizeHandle.bottomRight => rect.topLeft,
    };
  }

  void _startTextResize(TextResizeHandle handle) {
    final draft = _textDraft;
    if (draft == null || draft.text.isEmpty) return;
    _textResizeStart = draft;
    _textResizeHandle = handle;
    _textResizePointer = _textCorner(draft.rect, handle);
    _textAutoSizing = false;
  }

  void _updateTextResize(TextResizeHandle handle, Offset delta) {
    final start = _textResizeStart;
    final activeHandle = _textResizeHandle;
    final bounds = _selection;
    if (start == null || activeHandle != handle || bounds == null) return;

    _textResizePointer += delta;
    final baseRect = start.rect;
    final anchor = _textOppositeCorner(baseRect, handle);
    final baseCorner = _textCorner(baseRect, handle);
    final baseVector = baseCorner - anchor;
    final denominator =
        baseVector.dx * baseVector.dx + baseVector.dy * baseVector.dy;
    if (denominator <= 0) return;

    final pointer = Offset(
      _textResizePointer.dx.clamp(bounds.left, bounds.right).toDouble(),
      _textResizePointer.dy.clamp(bounds.top, bounds.bottom).toDouble(),
    );
    final pointerVector = pointer - anchor;
    var scale =
        (pointerVector.dx * baseVector.dx + pointerVector.dy * baseVector.dy) /
        denominator;

    var maxScale = double.infinity;
    if (baseVector.dx > 0) {
      maxScale = math.min(maxScale, (bounds.right - anchor.dx) / baseVector.dx);
    } else if (baseVector.dx < 0) {
      maxScale = math.min(maxScale, (bounds.left - anchor.dx) / baseVector.dx);
    }
    if (baseVector.dy > 0) {
      maxScale = math.min(
        maxScale,
        (bounds.bottom - anchor.dy) / baseVector.dy,
      );
    } else if (baseVector.dy < 0) {
      maxScale = math.min(maxScale, (bounds.top - anchor.dy) / baseVector.dy);
    }
    maxScale = math.min(maxScale, 8);
    scale = scale.clamp(0.25, maxScale).toDouble();

    final target = anchor + baseVector * scale;
    final rect = Rect.fromPoints(anchor, target);
    setState(() {
      _textDraft = start.copyWith(
        start: rect.topLeft,
        end: rect.bottomRight,
        fontSize: (start.fontSize * scale).clamp(8, 256).toDouble(),
      );
    });
  }

  void _finishTextResize(TextResizeHandle handle) {
    if (_textResizeHandle != handle) return;
    _textResizeStart = null;
    _textResizeHandle = null;
  }

  void _startTextMove() {
    final draft = _textDraft;
    if (draft == null || draft.text.isEmpty) return;
    _textMoveStart = draft;
    _textMoveOffset = Offset.zero;
  }

  void _updateTextMove(Offset delta) {
    final start = _textMoveStart;
    final bounds = _selection;
    if (start == null || bounds == null) return;

    _textMoveOffset += delta;
    final desired = start.rect.shift(_textMoveOffset);
    final limits = _textPositionLimits(bounds, desired.size);
    final left = desired.left.clamp(limits.left, limits.right).toDouble();
    final top = desired.top.clamp(limits.top, limits.bottom).toDouble();
    final rect = Rect.fromLTWH(left, top, desired.width, desired.height);
    setState(() {
      _textDraft = start.copyWith(start: rect.topLeft, end: rect.bottomRight);
    });
  }

  void _finishTextMove() {
    _textMoveStart = null;
    _textMoveOffset = Offset.zero;
  }

  void _deleteTextDraft() {
    if (_textDraft == null) return;
    _suppressTextListener = true;
    _textController.clear();
    _suppressTextListener = false;
    _textFocusNode.unfocus();
    _textResizeStart = null;
    _textResizeHandle = null;
    _textMoveStart = null;
    _textMoveOffset = Offset.zero;
    _textAutoSizing = false;
    if (mounted) {
      setState(() => _textDraft = null);
    }
  }

  Offset _clampToSelection(ScreenshotLayout layout, Offset point) {
    final selected = _selection;
    if (selected == null) return layout.clampToImage(point);
    final clampedToImage = layout.clampToImage(point);
    return Offset(
      clampedToImage.dx.clamp(selected.left, selected.right).toDouble(),
      clampedToImage.dy.clamp(selected.top, selected.bottom).toDouble(),
    );
  }

  void _startSelection(ScreenshotLayout layout, Offset point) {
    final start = layout.clampToImage(point);
    setState(() {
      _dragStart = start;
      _selection = null;
      _selectionCommitted = false;
      _activeTool = CaptureTool.selection;
      _annotations = const [];
      _draftAnnotation = null;
      _message = null;
    });
  }

  void _updateSelection(ScreenshotLayout layout, Offset point) {
    final start = _dragStart;
    if (start == null) return;
    final current = layout.clampToImage(point);
    setState(() {
      // Keep the rectangle visible while dragging, but do not show action
      // buttons until onPanEnd commits this selection.
      _selection = Rect.fromPoints(start, current);
      _selectionCommitted = false;
    });
  }

  void _finishSelection() {
    final selection = _selection;
    _dragStart = null;
    if (selection == null || selection.width < 4 || selection.height < 4) {
      setState(() {
        _selection = null;
        _selectionCommitted = false;
        _message = '请拖动选择一个更大的区域';
      });
      return;
    }

    setState(() {
      _activeTool = CaptureTool.selection;
      _selectionCommitted = true;
    });
  }

  void _startAnnotation(ScreenshotLayout layout, Offset point) {
    final selected = _selection;
    if (selected == null || !_selectionCommitted) return;
    final start = _clampToSelection(layout, point);
    setState(() {
      _dragStart = start;
      _draftAnnotation = ScreenshotAnnotation(
        tool: _activeTool,
        start: start,
        end: start,
        color: _selectedColor,
      );
      _message = null;
    });
  }

  void _updateAnnotation(ScreenshotLayout layout, Offset point) {
    final start = _dragStart;
    if (start == null || _activeTool == CaptureTool.selection) return;
    final current = _clampToSelection(layout, point);
    setState(() {
      _draftAnnotation = ScreenshotAnnotation(
        tool: _activeTool,
        start: start,
        end: current,
        color: _selectedColor,
      );
    });
  }

  void _finishAnnotation() {
    final draft = _draftAnnotation;
    _dragStart = null;
    _draftAnnotation = null;
    final isLargeEnough = draft == null
        ? false
        : draft.tool == CaptureTool.arrow
        ? (draft.end - draft.start).distance >= 4
        : draft.rect.shortestSide >= 4;
    if (!isLargeEnough) {
      setState(() => _message = '请拖动绘制一个更大的标注');
      return;
    }
    setState(() => _annotations = [..._annotations, draft]);
  }

  Future<Uint8List> _renderSelection(
    ScreenshotLayout layout,
    Rect selection,
  ) async {
    final image = _image;
    if (image == null) {
      throw const NativeBridgeException('截图图片尚未准备好');
    }

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

    // Convert the overlay's logical coordinates to the cropped image's pixel
    // coordinates. Save and copy therefore use exactly the same annotation
    // geometry that the user saw on the frozen screenshot.
    final cropOrigin = Offset(
      layout.imageRect.left + source.left * layout.scale,
      layout.imageRect.top + source.top * layout.scale,
    );
    canvas.save();
    canvas.clipRect(destination);
    for (final annotation in _annotations) {
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
      throw const NativeBridgeException('PNG 编码失败');
    }
    return data.buffer.asUint8List();
  }

  Future<void> _save(ScreenshotLayout layout) async {
    final selection = _selection;
    if (selection == null || _busy) return;
    _commitTextDraft();

    setState(() {
      _busy = true;
      _message = '正在生成 PNG…';
    });

    try {
      final png = await _renderSelection(layout, selection);
      final home = Platform.environment['HOME'];
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PNG 图片',
            extensions: ['png'],
            mimeTypes: ['image/png'],
          ),
        ],
        initialDirectory: home == null ? null : '$home/Pictures',
        suggestedName: 'hax-shot-${_timestamp()}.png',
        confirmButtonText: '保存',
      );
      if (location == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final path = location.path.toLowerCase().endsWith('.png')
          ? location.path
          : '${location.path}.png';
      await File(path).writeAsBytes(png, flush: true);
      await _closeCapture();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '保存失败：$error';
      });
    }
  }

  Future<void> _copy(ScreenshotLayout layout) async {
    final selection = _selection;
    if (selection == null || _busy) return;
    _commitTextDraft();

    setState(() {
      _busy = true;
      _message = '正在复制…';
    });

    try {
      final png = await _renderSelection(layout, selection);
      await NativeBridge.instance.copyPngToClipboard(png);
      await _closeCapture();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '复制失败：$error';
      });
    }
  }

  Future<void> _cancel() => _closeCapture();

  Future<void> _closeCapture() async {
    if (mounted) {
      setState(() => _busy = true);
    }
    await windowManager.close();
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_loading || image == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _message == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _cancel();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final layout = ScreenshotLayout.fromViewport(
                constraints.biggest,
                image,
              );
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  ScreenshotCanvas(
                    image: image,
                    layout: layout,
                    selection: _selection,
                    annotations: _annotations,
                    draftAnnotation: _draftAnnotation,
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      if (_activeTool == CaptureTool.text) {
                        _beginTextInput(layout, details.localPosition);
                      }
                    },
                    onPanStart: (details) {
                      if (_activeTool == CaptureTool.text) return;
                      if (_activeTool == CaptureTool.selection ||
                          _selection == null) {
                        _startSelection(layout, details.localPosition);
                      } else {
                        _startAnnotation(layout, details.localPosition);
                      }
                    },
                    onPanUpdate: (details) {
                      if (_activeTool == CaptureTool.text) return;
                      if (_activeTool == CaptureTool.selection ||
                          _selection == null) {
                        _updateSelection(layout, details.localPosition);
                      } else {
                        _updateAnnotation(layout, details.localPosition);
                      }
                    },
                    onPanEnd: (_) {
                      if (_activeTool == CaptureTool.text) return;
                      if (_activeTool == CaptureTool.selection ||
                          _selection == null) {
                        _finishSelection();
                      } else {
                        _finishAnnotation();
                      }
                    },
                    child: const SizedBox.expand(),
                  ),
                  if (_textDraft != null)
                    Positioned(
                      left:
                          _textDraft!.rect.left -
                          TextAnnotationEditor.horizontalInset,
                      top: _textDraft!.rect.top - TextAnnotationEditor.topInset,
                      width:
                          _textDraft!.rect.width +
                          TextAnnotationEditor.horizontalInset * 2,
                      height:
                          _textDraft!.rect.height +
                          TextAnnotationEditor.topInset +
                          TextAnnotationEditor.bottomInset,
                      child: TextAnnotationEditor(
                        annotation: _textDraft!,
                        controller: _textController,
                        focusNode: _textFocusNode,
                        onResizeStart: _startTextResize,
                        onResizeUpdate: _updateTextResize,
                        onResizeEnd: _finishTextResize,
                        onMoveStart: _startTextMove,
                        onMoveUpdate: _updateTextMove,
                        onMoveEnd: _finishTextMove,
                        onDelete: _deleteTextDraft,
                      ),
                    ),
                  if (_selection == null && _message == null)
                    const IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: EdgeInsets.only(top: 28),
                          child: Text(
                            '拖动鼠标框选截图区域 · Esc 取消',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              shadows: [Shadow(blurRadius: 4)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_message != null)
                    IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Color(0xDD202124),
                              borderRadius: BorderRadius.all(
                                Radius.circular(8),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Text(_message!),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_selectionCommitted && _selection != null)
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: CaptureToolbarLayoutDelegate(
                          selection: _selection!,
                        ),
                        child: CaptureToolbar(
                          enabled: true,
                          busy: _busy,
                          activeTool: _activeTool,
                          selectedColor: _selectedColor,
                          onToolSelected: _selectTool,
                          onColorSelected: _selectColor,
                          onCancel: _cancel,
                          onSave: () => _save(layout),
                          onCopy: () => _copy(layout),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
