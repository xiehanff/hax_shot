import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'annotation.dart';
import 'capture_session.dart';
import 'screenshot_canvas.dart';
import 'text_annotation_editor.dart';
import 'text_annotation_style.dart';

/// 文字标注编辑态的唯一 owner：当前正在编辑的 [ScreenshotAnnotation]、输入框里的
/// 光标与拖拽/缩放的起点、以及提交/取消逻辑。
///
/// 只持有状态与逻辑，不画任何东西（编辑框本身是 `text_annotation_editor.dart`）。
/// 测量统一走 `text_annotation_style.dart` 的 helper，不在这里另起一套规格，否则
/// “打字时看到的排版”和导出的 PNG 会不一致。
///
/// 选区/标注列表仍然属于 [CaptureSession]（本类按需读写它），页面只负责跟着
/// [ChangeNotifier] 重建。
class TextAnnotationState extends ChangeNotifier {
  /// [session] 是页面共享的选区/标注会话；[onClearMessage] 在开始编辑文字时
  /// 清掉页面顶层的提示文案（顶层文案归权限流程管）。
  TextAnnotationState(this._session, this._onClearMessage) {
    _controller.addListener(_handleTextChanged);
  }

  final CaptureSession _session;

  /// 开始编辑文字时会清掉页面顶层的提示文案，这里用回调把这件事交回页面。
  final VoidCallback _onClearMessage;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'capture-text');

  ScreenshotAnnotation? _draft;
  bool _autoSizing = false;
  bool _suppressListener = false;
  ScreenshotAnnotation? _resizeStart;
  TextResizeHandle? _resizeHandle;
  Offset _resizePointer = Offset.zero;
  ScreenshotAnnotation? _moveStart;
  Offset _moveOffset = Offset.zero;
  bool _disposed = false;

  ScreenshotAnnotation? get draft => _draft;

  TextEditingController get controller => _controller;

  FocusNode get focusNode => _focusNode;

  /// 点击画布：命中已有文字就重新打开编辑，否则新建一个空的输入框。
  void beginInput(ScreenshotLayout layout, Offset point) {
    if (!_session.hasCommittedSelection) return;

    commitDraft();
    final existing = _session.takeTextAnnotationAt(point);
    if (existing != null) {
      _edit(existing);
      return;
    }
    _create(layout, point);
  }

  /// 提交当前草稿：空文本直接丢弃，非空则写回会话的标注列表。
  void commitDraft() {
    final draft = _draft;
    if (draft == null) return;
    final text = _controller.text;
    final committed = text.isEmpty ? null : draft.copyWith(text: text);
    _setControllerText('');
    _focusNode.unfocus();
    _resetInteraction();
    _update(() {
      _draft = null;
      if (committed != null) {
        _session.addAnnotation(committed);
      }
    });
  }

  /// 色板改色时同步当前草稿的颜色（会话颜色由页面改）。
  void recolorDraft(Color color) {
    final draft = _draft;
    if (draft == null) return;
    _update(() => _draft = draft.copyWith(color: color));
  }

  void startResize(TextResizeHandle handle) {
    final draft = _draft;
    if (draft == null || draft.text.isEmpty) return;
    _resizeStart = draft;
    _resizeHandle = handle;
    _resizePointer = _corner(draft.rect, handle);
    _autoSizing = false;
  }

  void updateResize(TextResizeHandle handle, Offset delta) {
    final start = _resizeStart;
    final activeHandle = _resizeHandle;
    final bounds = _session.selection;
    if (start == null || activeHandle != handle || bounds == null) return;

    _resizePointer += delta;
    final baseRect = start.rect;
    final anchor = _oppositeCorner(baseRect, handle);
    final baseCorner = _corner(baseRect, handle);
    final baseVector = baseCorner - anchor;
    final denominator =
        baseVector.dx * baseVector.dx + baseVector.dy * baseVector.dy;
    if (denominator <= 0) return;

    final pointer = Offset(
      _resizePointer.dx.clamp(bounds.left, bounds.right).toDouble(),
      _resizePointer.dy.clamp(bounds.top, bounds.bottom).toDouble(),
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
    _update(() {
      _draft = start.copyWith(
        start: rect.topLeft,
        end: rect.bottomRight,
        fontSize: (start.fontSize * scale).clamp(8, 256).toDouble(),
      );
    });
  }

  void finishResize(TextResizeHandle handle) {
    if (_resizeHandle != handle) return;
    _resizeStart = null;
    _resizeHandle = null;
  }

  void startMove() {
    final draft = _draft;
    if (draft == null || draft.text.isEmpty) return;
    _moveStart = draft;
    _moveOffset = Offset.zero;
  }

  void updateMove(Offset delta) {
    final start = _moveStart;
    final bounds = _session.selection;
    if (start == null || bounds == null) return;

    _moveOffset += delta;
    final desired = start.rect.shift(_moveOffset);
    final limits = _positionLimits(bounds, desired.size);
    final left = desired.left.clamp(limits.left, limits.right).toDouble();
    final top = desired.top.clamp(limits.top, limits.bottom).toDouble();
    final rect = Rect.fromLTWH(left, top, desired.width, desired.height);
    _update(() {
      _draft = start.copyWith(start: rect.topLeft, end: rect.bottomRight);
    });
  }

  void finishMove() {
    _moveStart = null;
    _moveOffset = Offset.zero;
  }

  /// 编辑框上的删除按钮：丢掉草稿（不写回会话）。
  void deleteDraft() {
    if (_draft == null) return;
    _setControllerText('');
    _focusNode.unfocus();
    _resetInteraction();
    _update(() => _draft = null);
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _edit(ScreenshotAnnotation annotation) {
    _setControllerText(annotation.text);
    _resetInteraction();

    _update(() {
      _session.selectTool(CaptureTool.text);
      _session.selectColor(annotation.color);
      _draft = annotation;
      _onClearMessage();
    });
    _focusEditor();
  }

  void _create(ScreenshotLayout layout, Offset point) {
    final selection = _session.selection;
    if (selection == null) return;
    final start = _session.clampToSelection(layout, point);
    final rect = _rectForInput(
      requestedStart: start,
      text: '',
      fontSize: 24,
      bounds: selection,
    );
    _setControllerText('');
    _resetInteraction();

    _update(() {
      _session.selectTool(CaptureTool.text);
      _autoSizing = true;
      _draft = ScreenshotAnnotation(
        tool: CaptureTool.text,
        start: rect.topLeft,
        end: rect.bottomRight,
        color: _session.selectedColor,
        fontSize: 24,
      );
      _onClearMessage();
    });
    _focusEditor();
  }

  Rect _rectForInput({
    required Offset requestedStart,
    required String text,
    required double fontSize,
    required Rect bounds,
  }) {
    final measured = measureAnnotationText(
      text,
      fontSize: fontSize,
      maxWidth: bounds.width,
    );
    final width = math.min(
      math.max(measured.width + 4, 24).toDouble(),
      bounds.width,
    );
    final height = math.min(
      math.max(measured.height + 4, fontSize + 8).toDouble(),
      bounds.height,
    );
    final limits = _positionLimits(bounds, Size(width, height));
    final left = requestedStart.dx.clamp(limits.left, limits.right);
    final top = requestedStart.dy.clamp(limits.top, limits.bottom);
    return Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  Rect _positionLimits(Rect bounds, Size textSize) {
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
    if (_suppressListener || _disposed) return;
    final draft = _draft;
    if (draft == null) return;

    var updated = draft.copyWith(text: _controller.text);
    final selection = _session.selection;
    if (_autoSizing && selection != null) {
      final rect = _rectForInput(
        requestedStart: draft.start,
        text: _controller.text,
        fontSize: draft.fontSize,
        bounds: selection,
      );
      updated = updated.copyWith(start: rect.topLeft, end: rect.bottomRight);
    }
    _update(() => _draft = updated);
  }

  void _setControllerText(String text) {
    _suppressListener = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressListener = false;
  }

  void _resetInteraction() {
    _resizeStart = null;
    _resizeHandle = null;
    _resizePointer = Offset.zero;
    _moveStart = null;
    _moveOffset = Offset.zero;
    _autoSizing = false;
  }

  void _focusEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _draft == null) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  Offset _corner(Rect rect, TextResizeHandle handle) {
    return switch (handle) {
      TextResizeHandle.topLeft => rect.topLeft,
      TextResizeHandle.topRight => rect.topRight,
      TextResizeHandle.bottomLeft => rect.bottomLeft,
      TextResizeHandle.bottomRight => rect.bottomRight,
    };
  }

  Offset _oppositeCorner(Rect rect, TextResizeHandle handle) {
    return switch (handle) {
      TextResizeHandle.topLeft => rect.bottomRight,
      TextResizeHandle.topRight => rect.bottomLeft,
      TextResizeHandle.bottomLeft => rect.topRight,
      TextResizeHandle.bottomRight => rect.topLeft,
    };
  }

  void _update(void Function() change) {
    change();
    if (_disposed) return;
    notifyListeners();
  }
}
