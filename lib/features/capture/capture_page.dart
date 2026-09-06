import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../native/native_bridge.dart';
import 'annotation.dart';
import 'capture_session.dart';
import 'capture_toolbar.dart';
import 'screenshot_canvas.dart';
import 'screenshot_exporter.dart';
import 'selection_toolbar_placement.dart';
import 'text_annotation_editor.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final CaptureSession _session = CaptureSession();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode(debugLabel: 'capture-text');

  ui.Image? _image;
  String? _message;
  bool _loading = true;
  bool _busy = false;

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
    if (_busy) return;
    if (_session.activeTool == CaptureTool.text && tool != CaptureTool.text) {
      _commitTextDraft();
    }
    setState(() {
      _session.selectTool(tool);
      _message = null;
    });
  }

  void _selectColor(Color color) {
    setState(() {
      _session.selectColor(color);
      final draft = _textDraft;
      if (draft != null) {
        _textDraft = draft.copyWith(color: color);
      }
    });
  }

  void _startCanvasGesture(ScreenshotLayout layout, Offset point) {
    if (_session.isTextTool) return;
    setState(() {
      _session.startGesture(layout, point);
      _message = null;
    });
  }

  void _updateCanvasGesture(ScreenshotLayout layout, Offset point) {
    if (_session.isTextTool) return;
    setState(() => _session.updateGesture(layout, point));
  }

  void _finishCanvasGesture() {
    if (_session.isTextTool) return;
    setState(() {
      final message = _session.finishGesture();
      if (message != null) _message = message;
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
    final selection = _session.selection;
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

  void _setTextController(String text) {
    _suppressTextListener = true;
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressTextListener = false;
  }

  void _resetTextInteraction() {
    _textResizeStart = null;
    _textResizeHandle = null;
    _textResizePointer = Offset.zero;
    _textMoveStart = null;
    _textMoveOffset = Offset.zero;
    _textAutoSizing = false;
  }

  void _focusTextEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _textDraft == null) return;
      _textFocusNode.requestFocus();
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
  }

  void _editTextAnnotation(ScreenshotAnnotation annotation) {
    _setTextController(annotation.text);
    _resetTextInteraction();

    setState(() {
      _session.selectTool(CaptureTool.text);
      _session.selectColor(annotation.color);
      _textDraft = annotation;
      _message = null;
    });
    _focusTextEditor();
  }

  void _createTextInput(ScreenshotLayout layout, Offset point) {
    final selection = _session.selection;
    if (selection == null) return;
    final start = _session.clampToSelection(layout, point);
    final rect = _textRectForInput(
      requestedStart: start,
      text: '',
      fontSize: 24,
      bounds: selection,
    );
    _setTextController('');
    _resetTextInteraction();

    setState(() {
      _session.selectTool(CaptureTool.text);
      _textAutoSizing = true;
      _textDraft = ScreenshotAnnotation(
        tool: CaptureTool.text,
        start: rect.topLeft,
        end: rect.bottomRight,
        color: _session.selectedColor,
        fontSize: 24,
      );
      _message = null;
    });
    _focusTextEditor();
  }

  void _beginTextInput(ScreenshotLayout layout, Offset point) {
    if (!_session.hasCommittedSelection) return;

    _commitTextDraft();
    final existing = _session.takeTextAnnotationAt(point);
    if (existing != null) {
      _editTextAnnotation(existing);
      return;
    }
    _createTextInput(layout, point);
  }

  void _commitTextDraft() {
    final draft = _textDraft;
    if (draft == null) return;
    final text = _textController.text;
    final committed = text.isEmpty ? null : draft.copyWith(text: text);
    _setTextController('');
    _textFocusNode.unfocus();
    _resetTextInteraction();
    setState(() {
      _textDraft = null;
      if (committed != null) {
        _session.addAnnotation(committed);
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
    final bounds = _session.selection;
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
    final bounds = _session.selection;
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
    _setTextController('');
    _textFocusNode.unfocus();
    _resetTextInteraction();
    setState(() => _textDraft = null);
  }

  Future<void> _save(ScreenshotLayout layout) async {
    final selection = _session.selection;
    final image = _image;
    if (selection == null || image == null || _busy) return;
    _commitTextDraft();

    setState(() {
      _busy = true;
      _message = '正在生成 PNG…';
    });

    try {
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
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
    final selection = _session.selection;
    final image = _image;
    if (selection == null || image == null || _busy) return;
    _commitTextDraft();

    setState(() {
      _busy = true;
      _message = '正在复制…';
    });

    try {
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
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
                    selection: _session.selection,
                    annotations: _session.annotations,
                    draftAnnotation: _session.draftAnnotation,
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      if (_session.isTextTool) {
                        _beginTextInput(layout, details.localPosition);
                      }
                    },
                    onPanStart: (details) =>
                        _startCanvasGesture(layout, details.localPosition),
                    onPanUpdate: (details) =>
                        _updateCanvasGesture(layout, details.localPosition),
                    onPanEnd: (_) => _finishCanvasGesture(),
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
                  if (_session.selection == null && _message == null)
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
                  if (_session.hasCommittedSelection)
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: CaptureToolbarLayoutDelegate(
                          selection: _session.selection!,
                        ),
                        child: CaptureToolbar(
                          busy: _busy,
                          activeTool: _session.activeTool,
                          selectedColor: _session.selectedColor,
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
