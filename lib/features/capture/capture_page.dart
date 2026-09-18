import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/hax_ai_action.dart';
import '../../native/native_bridge.dart';
import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';
import '../window/panel_chrome.dart';
import '../window/rounded_window.dart';
import 'annotation.dart';
import 'capture_overlay_window.dart';
import 'capture_permission_flow.dart';
import 'capture_permission_guide.dart';
import 'capture_process_lifecycle.dart';
import 'capture_request_channel.dart';
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
  const CapturePage({
    required this.onAiAction,
    this.targetDisplay,
    this.requestId,
    super.key,
  });

  final CaptureAiActionCallback onAiAction;

  /// 当前进程是从哪块显示器启动的，重启抓屏进程时原样带上。
  final int? targetDisplay;

  /// 本次截图请求 id；抓屏成功/失败时写回 ACK 文件并记日志。
  final String? requestId;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  static const _captureTimeout = Duration(seconds: 5);

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
      requestId: widget.requestId,
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

      // 捕获窗口此时仍隐藏；原生抓屏若永久不返回，用户只会看到“快捷键没反应”，
      // 进程却一直占着捕获锁。超时后由下面的分支硬退出，释放进程内全部资源。
      final captureWatch = Stopwatch()..start();
      final path = await NativeBridge.instance.captureScreen().timeout(
        _captureTimeout,
        onTimeout: () => throw TimeoutException('抓屏超过 5 秒仍未完成'),
      );
      captureWatch.stop();
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
      // 先记冻结的目标（Windows），再回 ACK：日志里能直接对上“抓的是哪块屏”。
      final target = _logCaptureTarget(captureWatch.elapsedMilliseconds);
      // 抓到画面：宿主靠这条 ACK 区分「子进程起来了但抓屏失败」和「真的可以选了」。
      _ackRequest(
        CaptureRequestChannel.stateCaptureReady,
        DiagnosticEvent.captureReady,
      );
      // 抓到画面之后才把窗口升格成铺满屏幕的浮层。Windows 的原生桥读的是同一份
      // 冻结元数据；失败抛 CaptureOverlayException，由下面的分支走失败面板。
      final placement = await _process.showCaptureOverlay(
        generation: target?.generation,
      );
      if (!mounted) return;
      // 等一帧再读 viewport：窗口已经在 becomeOverlay 里改成目标尺寸，但 Flutter
      // 侧的视图尺寸要等这一帧才会更新到新值。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _logOverlayReady(placement, target);
    } on TimeoutException catch (error) {
      // Future.timeout 不能可靠取消正在执行 FFI 的 worker isolate。直接硬退出整个
      // 短生命周期捕获进程，才能保证原生调用、临时文件和捕获锁都不会继续残留。
      debugPrint('截图超时，结束捕获进程：$error');
      _ackRequest(
        CaptureRequestChannel.stateStartupFailed,
        DiagnosticEvent.captureStartupFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.captureStartupFailed,
        message: '抓屏超时：$error',
      );
      await _process.exitProcess();
    } on ScreenCapturePermissionException catch (error) {
      if (!mounted) return;
      _ackRequest(
        CaptureRequestChannel.stateStartupFailed,
        DiagnosticEvent.captureStartupFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.capturePermissionDenied,
        message: error.message,
      );
      await _flow.showGuide(message: error.message);
    } on CaptureOverlayException catch (error) {
      // 浮层失败是独立的失败态：不 fallback 主屏全屏、不显示旧图、不进 AI 面板，
      // 也不释放捕获锁（锁由进程持有，只有真的退出才释放）。
      if (!mounted) return;
      _ackRequest(
        CaptureRequestChannel.stateStartupFailed,
        DiagnosticEvent.overlayBecomeFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.overlayBecomeFailed,
        message: 'native code=${error.code} ${error.message}',
      );
      _flow.enterFailure(error);
      await _flow.revealWindow();
    } on Object catch (error) {
      if (!mounted) return;
      // 其它失败也留在小窗口里说明情况，别让用户卡在全屏黑屏上。
      _ackRequest(
        CaptureRequestChannel.stateStartupFailed,
        DiagnosticEvent.captureStartupFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.captureStartupFailed,
        message: '$error',
      );
      _flow.enterFailure(error);
      await _flow.revealWindow();
    }
  }

  /// 把原生**冻结**的目标显示器元数据写进诊断日志（Windows；其它平台没有这套 ABI）。
  ///
  /// 只读日志用途：读元数据失败不能反过来把已经成功的抓屏变成失败，所以这里自己
  /// 兜住所有错误。摆浮层用的一定是同一份冻结数据（§8.5），不会出现“抓 A 摆 B”。
  ///
  /// 返回值给调用方用来 1) 给 `becomeOverlay` 带 generation；2) 核对物理契约。
  ///
  /// [elapsedMilliseconds] 是 `captureScreen()` 这个 FFI 调用的墙钟耗时（含 worker
  /// isolate 的往返）；原生侧没有日志出口，所以耗时在调用边界上量。
  CaptureTargetMonitor? _logCaptureTarget(int elapsedMilliseconds) {
    try {
      final target = NativeBridge.instance.lastCaptureTarget();
      if (target == null) return null;
      DiagnosticLogService.instance.log(
        DiagnosticEvent.captureTargetResolved,
        requestId: widget.requestId,
        message: 'backend=gdi $target capture_call_ms=$elapsedMilliseconds',
      );
      if (target.suspectedBlank) {
        // 全黑只是告警：黑桌面是合法画面，不回退、不重截、不写截图内容（§9.8）。
        DiagnosticLogService.instance.log(
          DiagnosticEvent.captureSuspectedBlank,
          level: LogLevel.warning,
          requestId: widget.requestId,
          message:
              '疑似全黑（仅告警）：mean_luma=${target.meanLuma} '
              'size=${target.width}x${target.height} '
              'display_id=${target.displayId}',
        );
      }
      return target;
    } on Object catch (error) {
      debugPrint('读取冻结的抓屏目标失败：$error');
      return null;
    }
  }

  /// 浮层就绪 + 物理契约核对（§13.5）：原生 `GetClientRect`、冻结的 rcMonitor、
  /// PNG 尺寸、Flutter 侧的 viewport 与 dpr 写进同一条日志。
  ///
  /// 对不上时的修法是查窗口链路（bridge 的 GetClientRect / WM_NCCALCSIZE / DPI），
  /// **不是**给选区加补偿边距（§13.5/§47）。这里只记录，不改任何行为。
  void _logOverlayReady(
    CaptureOverlayPlacement? placement,
    CaptureTargetMonitor? target,
  ) {
    final view = View.of(context);
    // physicalSize 已经是物理像素；逻辑 viewport 要自己除 dpr。
    final Size physical = view.physicalSize;
    final double dpr = view.devicePixelRatio;
    final Size logical = dpr > 0 ? physical / dpr : Size.zero;
    // ScreenshotLayout.fromViewport 收到的是逻辑 viewport，除以 PNG 的物理宽度就是
    // 选区的缩放系数：必须 ≈ 1 / dpr（§13.5 第三条）。
    final image = _image;
    final double? layoutScale = image == null || image.width == 0
        ? null
        : logical.width / image.width;
    final client = placement?.clientRect;

    final clientLabel = client == null
        ? 'client=unknown'
        : 'client=(${client.left.toInt()},${client.top.toInt()},'
              '${client.right.toInt()},${client.bottom.toInt()})';
    final targetLabel = target == null
        ? 'rcMonitor=unknown'
        : 'rcMonitor=(${target.left},${target.top},${target.right},${target.bottom})';
    final imageLabel = image == null
        ? 'png=unknown'
        : 'png=${image.width}x${image.height}';

    // 契约（§13.5）：GetClientRect == rcMonitor == PNG == View.physicalSize，且
    // 选区缩放系数 ≈ 1 / dpr。非 Windows 没有原生摆位数据，不当作契约失败。
    bool contractHolds(
      CaptureOverlayPlacement native,
      CaptureTargetMonitor frozen,
      ui.Image png,
    ) {
      final Rect clientRect = native.clientRect;
      final bool clientOk =
          clientRect.width.toInt() == frozen.width &&
          clientRect.height.toInt() == frozen.height;
      final bool viewportOk =
          (physical.width - frozen.width).abs() <= 1 &&
          (physical.height - frozen.height).abs() <= 1;
      final bool pngOk =
          png.width == frozen.width && png.height == frozen.height;
      final bool scaleOk =
          layoutScale != null && (layoutScale - 1 / dpr).abs() <= 0.01;
      return clientOk && viewportOk && pngOk && scaleOk;
    }

    final bool hasNativePlacement = placement != null && target != null;
    final bool contractOk =
        placement != null &&
        target != null &&
        image != null &&
        contractHolds(placement, target, image);

    DiagnosticLogService.instance.log(
      DiagnosticEvent.overlayReady,
      level: hasNativePlacement && !contractOk
          ? LogLevel.warning
          : LogLevel.info,
      requestId: widget.requestId,
      message:
          '$clientLabel $targetLabel $imageLabel dpi=${placement?.dpi} '
          'viewport=${physical.width.round()}x${physical.height.round()} '
          'logical=${logical.width.round()}x${logical.height.round()} dpr=$dpr '
          'layout_scale=${layoutScale?.toStringAsFixed(4)} '
          'contract_ok=$contractOk',
      extra: <String, Object?>{
        'client_width': client?.width.round(),
        'client_height': client?.height.round(),
        'target_width': target?.width,
        'target_height': target?.height,
        'viewport_width': physical.width.round(),
        'viewport_height': physical.height.round(),
        'device_pixel_ratio': dpr,
        'layout_scale': layoutScale,
        'contract_ok': contractOk,
      },
    );
  }

  /// 把当前阶段写回请求文件（宿主在等）并记一条日志。
  ///
  /// 日志**无条件**写：没有 `--request-id` 的手动启动（`hax_shot.exe --capture`）也
  /// 必须能在诊断日志里看到失败原因与浮层的 native code（§17）；请求文件只在有
  /// requestId 时才存在。
  void _ackRequest(
    String state,
    String event, {
    String level = LogLevel.info,
    String? errorCode,
    String? message,
  }) {
    final requestId = widget.requestId;
    if (requestId != null) {
      CaptureRequestChannel.instance.writeStateSync(requestId, state);
    }
    DiagnosticLogService.instance.log(
      event,
      level: level,
      requestId: requestId,
      errorCode: errorCode,
      message: message,
    );
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
      //
      // Windows 不猜目录（§34）：`USERPROFILE\Pictures` 可能被 OneDrive 重定向或
      // 根本不存在，交给系统对话框自己的默认行为最可预测；HOME 缺失时同样不强猜。
      final String? home = Platform.environment['HOME'];
      final String? initialDirectory = Platform.isWindows
          ? null
          : (home == null ? null : '$home/Pictures');
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PNG 图片',
            extensions: ['png'],
            mimeTypes: ['image/png'],
          ),
        ],
        initialDirectory: initialDirectory,
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
                          onExtractText: () =>
                              _askAi(HaxAiAction.extractText, layout),
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
