import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/hax_ai_action.dart';
import '../../native/native_bridge.dart';
import '../window/panel_chrome.dart';
import '../window/rounded_window.dart';
import 'annotation.dart';
import 'capture_permission_flow.dart';
import 'capture_permission_guide.dart';
import 'capture_process_lifecycle.dart';
import 'capture_session.dart';
import 'capture_toolbar.dart';
import 'screenshot_canvas.dart';
import 'screenshot_exporter.dart';
import 'selection_toolbar_placement.dart';
import 'text_annotation_editor.dart';
import 'text_annotation_state.dart';

typedef CaptureAiActionCallback =
    Future<void> Function(HaxAiAction action, Uint8List pngBytes);

class CapturePage extends StatefulWidget {
  const CapturePage({required this.onAiAction, this.targetDisplay, super.key});

  final CaptureAiActionCallback onAiAction;

  /// 当前进程是从哪块显示器启动的，重启抓屏进程时原样带上。
  final int? targetDisplay;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  final CaptureSession _session = CaptureSession();

  /// 抓屏进程/窗口生命周期。流程与文案状态在 [_flow]，文字编辑状态在 [_annotation]，
  /// 页面只留「截图内容 + 工具条」这点编排。
  late final CaptureProcessLifecycle _process;
  late final CapturePermissionFlow _flow;
  late final TextAnnotationState _annotation;

  ui.Image? _image;
  bool _busy = false;

  /// 复制进行中（只用于防重复点击，不驱动任何 loading UI）。
  /// 保存/复制各自的重入标志：它们都不进入 busy/loading 状态，只防重复触发。
  bool _copying = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _process = CaptureProcessLifecycle(
      targetDisplay: widget.targetDisplay,
      onRelaunchError: (error) => _flow.showMessage('重启抓屏进程失败：$error'),
    );
    _flow = CapturePermissionFlow(
      onRetryCapture: _capture,
      onRelaunchCaptureProcess: _process.relaunch,
      onQuit: () => unawaited(_process.close()),
      isMacOS: () => Platform.isMacOS,
    );
    _annotation = TextAnnotationState(_session, () => _flow.showMessage(null));
    _flow.addListener(_handleFlowChanged);
    _annotation.addListener(_handleAnnotationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  /// 权限流程与文字标注状态都在自己的类里改字段，页面只负责跟着重建。
  void _handleFlowChanged() {
    if (mounted) setState(() {});
  }

  void _handleAnnotationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户去系统设置授权再切回来时，比轮询更快地重查一次。
    if (state == AppLifecycleState.resumed) {
      unawaited(_flow.checkPermissionWhileWaiting());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flow.removeListener(_handleFlowChanged);
    _annotation.removeListener(_handleAnnotationChanged);
    _flow.dispose();
    _annotation.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    try {
      // 先问权限：没有屏幕录制授权时抓屏一定失败，这时必须显示引导，而不是把
      // 全屏浮层弹出来盖住用户的桌面。预检也在 try 里，且用安全查询：查询本身
      // 失败（原生库缺失）属于平台无关的失败，不是「缺授权」。
      // 预检的两种收尾（引导页 / 失败面板）都由 flow 负责，这里只看能不能继续。
      if (!await _flow.allowCapture()) return;

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
      setState(() => _image = frame.image);
      _flow.markCaptureSucceeded();
      // 抓到画面之后才把窗口升格成铺满屏幕的浮层。
      await _process.showCaptureOverlay();
    } on ScreenCapturePermissionException catch (error) {
      if (!mounted) return;
      await _flow.showGuide(message: error.message);
    } on Object catch (error) {
      if (!mounted) return;
      // 其它失败也留在小窗口里说明情况，别让用户卡在全屏黑屏上。
      _flow.enterFailure(error);
      await _flow.revealWindow();
    }
  }

  void _selectTool(CaptureTool tool) {
    if (_busy) return;
    if (_session.activeTool == CaptureTool.text && tool != CaptureTool.text) {
      _annotation.commitDraft();
    }
    setState(() => _session.selectTool(tool));
    _flow.showMessage(null);
  }

  void _selectColor(Color color) {
    setState(() => _session.selectColor(color));
    _annotation.recolorDraft(color);
  }

  void _startCanvasGesture(ScreenshotLayout layout, Offset point) {
    if (_session.isTextTool) return;
    setState(() => _session.startGesture(layout, point));
    _flow.showMessage(null);
  }

  void _updateCanvasGesture(ScreenshotLayout layout, Offset point) {
    if (_session.isTextTool) return;
    setState(() => _session.updateGesture(layout, point));
  }

  void _finishCanvasGesture() {
    if (_session.isTextTool) return;
    final message = _session.finishGesture();
    setState(() {});
    if (message != null) _flow.showMessage(message);
  }

  void _beginTextInput(ScreenshotLayout layout, Offset point) {
    _annotation.beginInput(layout, point);
  }

  Future<Uint8List> _renderSelectedPngForAi(ScreenshotLayout layout) async {
    _annotation.commitDraft();
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
    if (_busy) return;

    setState(() => _busy = true);
    _flow.showMessage('正在准备 AI 请求…');

    try {
      final png = await _renderSelectedPngForAi(layout);
      // AI 面板接管同一个窗口（app.dart 会把它改成面板尺寸并显示对话）。
      // 这里刻意不再关闭捕获进程：以前靠一个“忽略下一次关闭”的标志来
      // 阻止进程退出，一旦标志没被消费，窗口就会永远停在截图态且 Esc 失效。
      await widget.onAiAction(action, png);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _flow.showMessage('AI 请求失败：$error');
    }
  }

  Future<void> _save(ScreenshotLayout layout) async {
    final selection = _session.selection;
    final image = _image;
    if (selection == null || image == null || _busy || _saving) return;
    // 保存要弹系统对话框，用户等的是对话框而不是 loading，所以和 _copy 一样用
    // 私有标志防重复触发：连点两次不能弹两个对话框、更不能两条落盘链路竞争。
    _saving = true;
    _annotation.commitDraft();

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
      if (location == null) {
        _saving = false;
        return;
      }

      final path = location.path.toLowerCase().endsWith('.png')
          ? location.path
          : '${location.path}.png';
      await _process.hideOverlay();
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
      await File(path).writeAsBytes(png, flush: true);
      await _process.close();
    } on Object catch (error) {
      _saving = false;
      if (!mounted) return;
      await _process.restoreOverlay();
      if (!mounted) return;
      setState(() => _busy = false);
      _flow.showMessage('保存失败：$error');
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
    _annotation.commitDraft();

    try {
      // 先收浮层再编码：编码要 100~300ms，用户点完“复制”就应该立刻回到原来的
      // 界面。人切换到目标应用再按 ⌘V 至少也要几百毫秒，编码早就完成了。
      await _process.hideOverlay();
      final png = await ScreenshotExporter.renderPng(
        image: image,
        layout: layout,
        selection: selection,
        annotations: _session.annotations,
      );
      await NativeBridge.instance.copyPngToClipboard(png);
      await _process.close();
    } on Object catch (error) {
      _copying = false;
      await _process.restoreOverlay();
      if (!mounted) return;
      _flow.showMessage('复制失败：$error');
    }
  }

  Future<void> _cancel() => _process.close();

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// 平台无关的失败面板：Linux 抓屏失败、原生库查不到授权等都走这里，不再落进
  /// macOS 专属的授权引导页（那条路只留给「确实缺权限」）。
  ///
  /// 刻意不提供「打开系统设置 / 我已授权，重新检查 / 重置授权记录」：这些状态下
  /// 无法证明是权限问题，摆出 macOS 的入口只会误导用户。窗口尺寸沿用抓屏小窗口，
  /// 这里不负责设原生窗口大小。
  Widget _buildFailurePanel(String failure) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _process.close,
      },
      child: Focus(
        autofocus: true,
        child: RoundedWindow(
          child: Scaffold(
            backgroundColor: PanelColors.bg,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                PanelHeader(
                  icon: Icons.error_outline,
                  title: '截图失败',
                  onClose: _process.close,
                ),
                Expanded(
                  // 顶部对齐 + 可滚动：错误文案长度不可控，不能让它把按钮挤出去。
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          PanelNote(
                            icon: Icons.error_outline,
                            tone: PanelNoteTone.danger,
                            text: failure,
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: <Widget>[
                              FilledButton.icon(
                                onPressed: _flow.retryAfterPermission,
                                style: PanelButtons.primary,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('重试'),
                              ),
                              TextButton.icon(
                                onPressed: _process.close,
                                style: PanelButtons.ghost,
                                icon: const Icon(Icons.close, size: 15),
                                label: const Text('关闭'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_flow.needsPermission) {
      return CapturePermissionGuide(
        message: _flow.message,
        onRetry: _flow.retryAfterPermission,
        onQuit: _flow.quit,
        onResetPermission: _flow.resetPermissionAction,
      );
    }

    // 非权限类失败（Linux 抓屏失败、原生库查询不到授权…）走平台无关的失败面板。
    final failure = _flow.failureMessage;
    if (failure != null) {
      return _buildFailurePanel(failure);
    }

    final image = _image;
    if (_flow.loading || image == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _flow.message == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _flow.message!,
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
              final draft = _annotation.draft;
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
                  if (draft != null)
                    Positioned(
                      left:
                          draft.rect.left -
                          TextAnnotationEditor.horizontalInset,
                      top: draft.rect.top - TextAnnotationEditor.topInset,
                      width:
                          draft.rect.width +
                          TextAnnotationEditor.horizontalInset * 2,
                      height:
                          draft.rect.height +
                          TextAnnotationEditor.topInset +
                          TextAnnotationEditor.bottomInset,
                      child: TextAnnotationEditor(
                        annotation: draft,
                        controller: _annotation.controller,
                        focusNode: _annotation.focusNode,
                        onResizeStart: _annotation.startResize,
                        onResizeUpdate: _annotation.updateResize,
                        onResizeEnd: _annotation.finishResize,
                        onMoveStart: _annotation.startMove,
                        onMoveUpdate: _annotation.updateMove,
                        onMoveEnd: _annotation.finishMove,
                        onDelete: _annotation.deleteDraft,
                      ),
                    ),
                  if (_session.selection == null && _flow.message == null)
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
                  if (_flow.message != null)
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
                              child: Text(_flow.message!),
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
                          onTranslate: () =>
                              _askAi(HaxAiAction.translate, layout),
                          onExplain: () => _askAi(HaxAiAction.explain, layout),
                          onDeepUnderstand: () =>
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
