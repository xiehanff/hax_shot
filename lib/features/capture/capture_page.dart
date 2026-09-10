import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../native/native_bridge.dart';
import '../app/hard_exit.dart';
import '../settings/screen_capture_permission.dart';
import '../ai/models/hax_ai_action.dart';
import 'annotation.dart';
import 'capture_overlay_window.dart';
import 'capture_permission_guide.dart';
import 'capture_session.dart';
import '../window/window_visibility.dart';
import 'capture_toolbar.dart';
import 'screenshot_canvas.dart';
import 'screenshot_exporter.dart';
import 'selection_toolbar_placement.dart';
import 'text_annotation_editor.dart';

typedef CaptureAiActionCallback =
    Future<void> Function(HaxAiAction action, Uint8List pngBytes);

class CapturePage extends StatefulWidget {
  const CapturePage({this.onAiAction, this.targetDisplay, super.key});

  final CaptureAiActionCallback? onAiAction;

  /// 当前进程是从哪块显示器启动的，重启抓屏进程时原样带上。
  final int? targetDisplay;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  final CaptureSession _session = CaptureSession();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode(debugLabel: 'capture-text');

  ui.Image? _image;
  String? _message;
  bool _loading = true;
  bool _busy = false;

  /// 复制进行中（只用于防重复点击，不驱动任何 loading UI）。
  bool _copying = false;

  /// 正在关闭捕获进程（也刻意不驱动 loading UI）。
  bool _closing = false;

  /// 等待授权期间的轮询：和 hax_pick 一样，授权成功后自动继续，不需要用户点按钮。
  ///
  /// 注意 macOS 抓屏授权是**按进程缓存**的，所以这里检测到已授权后不是原地继续，
  /// 而是重启一个新的抓屏进程（新进程才读得到新授权）。
  Timer? _permissionPoll;
  static const _permissionPollInterval = Duration(milliseconds: 750);

  /// 没有屏幕录制权限（或抓屏失败）时显示引导页。
  ///
  /// 这两种情况都必须留在小窗口里：用户可能还没授权，如果把全屏浮层弹出来，
  /// 整块屏幕会被盖住，连菜单栏都点不到。
  bool _needsPermission = false;

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
    WidgetsBinding.instance.addObserver(this);
    _textController.addListener(_handleTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户去系统设置授权再切回来时，比轮询更快地重查一次。
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkPermissionWhileWaiting());
    }
  }

  void _startPermissionPolling() {
    _permissionPoll ??= Timer.periodic(
      _permissionPollInterval,
      (_) => unawaited(_checkPermissionWhileWaiting()),
    );
  }

  void _stopPermissionPolling() {
    _permissionPoll?.cancel();
    _permissionPoll = null;
  }

  /// 等待授权时的轮询回调：已授权就重启抓屏进程继续截图。
  Future<void> _checkPermissionWhileWaiting() async {
    if (!mounted || !_needsPermission) return;
    if (!NativeBridge.instance.screenCaptureAuthorized()) return;
    _stopPermissionPolling();
    if (mounted) setState(() => _message = '检测到已授权，正在继续…');
    await _relaunchCaptureProcess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPermissionPolling();
    _textController.removeListener(_handleTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    // 先问权限：没有屏幕录制授权时抓屏一定失败，这时必须显示引导，而不是把
    // 全屏浮层弹出来盖住用户的桌面。
    if (!NativeBridge.instance.screenCaptureAuthorized()) {
      await _showGuide();
      return;
    }

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
        _needsPermission = false;
      });
      // 抓到画面之后才把窗口升格成铺满屏幕的浮层。
      await CaptureOverlayWindow.instance.becomeOverlay();
      // Reveal the frozen screenshot only after native capture completes.
      await showWindow();
      await windowManager.focus();
    } on ScreenCapturePermissionException catch (error) {
      if (!mounted) return;
      await _showGuide(message: error.message);
    } on Object catch (error) {
      if (!mounted) return;
      // 其它失败也留在小窗口里说明情况，别让用户卡在全屏黑屏上。
      setState(() {
        _loading = false;
        _needsPermission = true;
        _message = '截图失败：$error';
      });
      await showWindow();
      await windowManager.focus();
    }
  }

  /// 没有授权（或抓屏失败）时显示引导页：普通小窗口，随时可以关掉。
  Future<void> _showGuide({String? message}) async {
    // 触发一次系统授权请求：这样 Hax Shot 才会出现在“屏幕录制”列表里，
    // 用户点“打开系统设置”才能找到它。用户确认前返回值是 false。
    NativeBridge.instance.requestScreenCaptureAccess();
    _startPermissionPolling();
    if (mounted) {
      setState(() {
        _loading = false;
        _needsPermission = true;
        _message = message;
      });
    }
    await showWindow();
    await windowManager.focus();
  }

  /// 用户在引导页点了“我已授权，重新检查”（轮询已经能自动发现，这里保留手动入口）。
  ///
  /// macOS 会把 TCC 结果缓存到进程结束，所以刚授权完这个进程通常还认为没权限；
  /// 直接原地重试会一直失败。这里改成**重启一个新的抓屏进程**（新进程重新读授权
  /// 状态），当前进程随即退出，用户只需要点一次。
  Future<void> _retryAfterPermission() async {
    if (NativeBridge.instance.screenCaptureAuthorized()) {
      if (mounted) setState(() => _loading = true);
      await _capture();
      return;
    }

    await _relaunchCaptureProcess();
  }

  /// 重置系统的屏幕录制授权记录，然后重启抓屏进程重新申请授权。
  ///
  /// 针对“系统设置里开关是开的，但当前进程没有权限、也不再弹授权框”的死结：
  /// 本地 ad-hoc 签名每次构建都会换指纹，旧记录和新二进制对不上。
  Future<void> _resetPermission() async {
    _stopPermissionPolling();
    try {
      await ScreenCapturePermission.instance.reset();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '重置授权记录失败：$error');
      return;
    }
    await _relaunchCaptureProcess();
  }

  Future<void> _relaunchCaptureProcess() async {
    try {
      final args = <String>[
        '--capture',
        if (widget.targetDisplay != null) ...[
          '--display',
          '${widget.targetDisplay}',
        ],
      ];
      await Process.start(
        Platform.resolvedExecutable,
        args,
        mode: ProcessStartMode.detached,
      );
      await _exitProcess();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '重启抓屏进程失败：$error');
    }
  }

  /// 结束当前捕获进程。
  ///
  /// 用硬退出（见 features/app/hard_exit.dart）：`exit(0)` 在 macOS 上会挂在引擎
  /// 收尾里，进程会残留；`windowManager.destroy()` 又要多等几百毫秒。
  Future<void> _exitProcess() async {
    exitProcessNow();
  }

  /// 收起浮层，让用户不用盯着冻结画面等编码/落盘。
  ///
  /// 实测一张 Retina 尺寸（3024x1964）选区的 PNG 编码约 100~300ms，退出进程还有
  /// 几十毫秒；这些都必须发生在浮层消失之后，否则“保存/复制”看起来就是卡住。
  /// 收起失败也不能中断后续动作，否则用户既没拿到图、窗口也没了。
  Future<void> _hideOverlay() async {
    try {
      await windowManager.hide();
    } on Object catch (error) {
      debugPrint('收起浮层失败：$error');
    }
  }

  /// 出错时把浮层放回来，让用户看得见错误信息。
  Future<void> _restoreOverlay() async {
    try {
      await windowManager.show();
    } on Object catch (error) {
      debugPrint('恢复浮层失败：$error');
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

  Future<Uint8List> _renderSelectedPngForAi(ScreenshotLayout layout) async {
    _commitTextDraft();
    final image = _image;
    final selection = _session.selection;
    if (image == null || selection == null) {
      throw StateError('没有可提交给 AI 的截图区域');
    }

    return ScreenshotExporter.renderPng(
      image: image,
      layout: layout,
      selection: selection,
      annotations: _session.annotations,
    );
  }

  Future<void> _askAi(HaxAiAction action, ScreenshotLayout layout) async {
    final onAiAction = widget.onAiAction;
    if (onAiAction == null || _busy) return;

    setState(() {
      _busy = true;
      _message = '正在准备 AI 请求…';
    });

    try {
      final png = await _renderSelectedPngForAi(layout);
      // AI 面板接管同一个窗口（app.dart 会把它改成面板尺寸并显示对话）。
      // 这里刻意不再调用 _closeCapture()：以前靠一个“忽略下一次关闭”的标志来
      // 阻止进程退出，一旦标志没被消费，窗口就会永远停在截图态且 Esc 失效。
      await onAiAction(action, png);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'AI 请求失败：$error';
      });
    }
  }

  Future<void> _save(ScreenshotLayout layout) async {
    final selection = _session.selection;
    final image = _image;
    if (selection == null || image == null || _busy) return;
    _commitTextDraft();

    try {
      // 先弹保存对话框（用户需要看着冻结画面选目录），选完路径立刻收起浮层，
      // 后面的编码和落盘都在浮层消失之后完成。
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
      if (location == null) return;

      final path = location.path.toLowerCase().endsWith('.png')
          ? location.path
          : '${location.path}.png';
      await _hideOverlay();
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
      await File(path).writeAsBytes(png, flush: true);
      await _closeCapture();
    } on Object catch (error) {
      if (!mounted) return;
      await _restoreOverlay();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '保存失败：$error';
      });
    }
  }

  /// 复制选区到剪贴板。
  ///
  /// 刻意不进入 busy/loading 状态：复制是“点一下就该进剪贴板”的操作，先收浮层
  /// 再编码，用户看不到任何等待。用一个私有标志只防重复点击。
  Future<void> _copy(ScreenshotLayout layout) async {
    final selection = _session.selection;
    final image = _image;
    if (selection == null || image == null || _busy || _copying) return;
    _copying = true;
    _commitTextDraft();

    try {
      // 先收浮层再编码：编码要 100~300ms，用户点完“复制”就应该立刻回到原来的
      // 界面。人切换到目标应用再按 ⌘V 至少也要几百毫秒，编码早就完成了。
      await _hideOverlay();
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
      await NativeBridge.instance.copyPngToClipboard(png);
      await _closeCapture();
    } on Object catch (error) {
      _copying = false;
      await _restoreOverlay();
      if (!mounted) return;
      setState(() => _message = '复制失败：$error');
    }
  }

  Future<void> _cancel() => _closeCapture();

  /// 关闭捕获窗口（Esc / 保存 / 复制 / 取消）。
  ///
  /// 必须走 `windowManager.close()`：AI 面板和框选界面共用同一个窗口，点 AI 时
  /// `app.dart` 会把 `_ignoreNextWindowClose` 置位来吃掉这一次关闭请求，让进程
  /// 继续跑 AI 对话。如果这里直接 exit 掉进程，AI 面板会立刻消失。
  Future<void> _closeCapture() async {
    if (_closing) return;
    _closing = true;
    // 不要在这里置 _busy：工具条会因此转圈，而复制/保存之后马上就要退出进程，
    // 用户看到的就是一个没必要的 loading（关闭链路万一没生效还会一直卡着）。
    // 正常路径是 close() → app.dart 的 onWindowClose → destroy + exit(0)；
    // 下面的兜底保证即使那条链路没生效，窗口也不会带着 loading 留在屏幕上。
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        unawaited(_exitProcess());
      }),
    );
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
    if (_needsPermission) {
      return CapturePermissionGuide(
        message: _message,
        onRetry: _retryAfterPermission,
        onQuit: _closeCapture,
        onResetPermission: Platform.isMacOS ? _resetPermission : null,
      );
    }

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
                          onTranslate: widget.onAiAction == null
                              ? null
                              : () => _askAi(HaxAiAction.translate, layout),
                          onExplain: widget.onAiAction == null
                              ? null
                              : () => _askAi(HaxAiAction.explain, layout),
                          onDeepUnderstand: widget.onAiAction == null
                              ? null
                              : () =>
                                    _askAi(HaxAiAction.deepUnderstand, layout),
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
