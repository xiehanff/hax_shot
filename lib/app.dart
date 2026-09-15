import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/ai/controllers/hax_ai_controller.dart';
import 'models/hax_ai_action.dart';
import 'features/ai/services/hax_ai_service.dart';
import 'features/ai/services/hax_ai_settings_store.dart';
import 'features/ai/views/ai_page.dart';
import 'features/app/hard_exit.dart';
import 'features/app/single_instance_guard.dart';
import 'features/capture/capture_launcher.dart';
import 'features/capture/capture_overlay_window.dart';
import 'features/capture/capture_page.dart';
import 'features/capture/capture_permission_guide.dart';
import 'features/capture/capture_request_channel.dart';
import 'features/diagnostics/app_lifecycle_bridge.dart';
import 'features/diagnostics/diagnostic_events.dart';
import 'features/diagnostics/diagnostic_log.dart';
import 'features/onboarding/first_run_guide.dart';
import 'features/onboarding/first_run_onboarding.dart';
import 'features/settings/screen_capture_permission.dart';
import 'features/settings/shortcut_registration.dart';
import 'features/settings/shortcut_service.dart';
import 'features/settings/shortcut_settings_page.dart';
import 'features/window/window_visibility.dart';
import 'hax_colors.dart';

import 'native/native_bridge.dart';

class HaxShotApp extends StatefulWidget {
  const HaxShotApp({
    required this.captureMode,
    this.targetDisplay,
    this.debugAiPanel = false,
    this.requestId,
    super.key,
  });

  final bool captureMode;

  /// `--display <id>`：主浮层要落在哪块显示器（重启抓屏进程时原样带上）。
  final int? targetDisplay;

  /// `--request-id`：本次截图请求 id，用于把宿主 / 子进程的诊断日志串起来。
  final String? requestId;

  /// debug 构建的 `--capture --debug-ai`：不抓屏，直接把窗口显示成 AI 面板。
  final bool debugAiPanel;

  @override
  State<HaxShotApp> createState() => _HaxShotAppState();
}

class _HaxShotAppState extends State<HaxShotApp> with WindowListener {
  // 宽度沿用 Plume 的侧栏比例（456 = 6px 把手 + 320 侧栏的观感），高度刻意留矮
  // 一点，别占满整块屏。
  //
  // 同时也是聊天窗口的**最小尺寸**：允许用户拖边缘改大，但不允许比默认尺寸更小
  //（见 _configureAiWindow）。
  static const Size _aiWindowSize = Size(456, 680);

  HaxAiController? _aiController;
  Future<void>? _aiInitialization;
  bool _showAiPage = false;
  bool _allowClose = false;

  @override
  void initState() {
    super.initState();
    if (!widget.captureMode) return;

    final service = HaxAiService(settingsStore: HaxAiSettingsStore());
    // 控制器由本 State 显式拥有（不经 GetX registry），dispose 时自己销毁。
    _aiController = HaxAiController(service: service);
    _aiInitialization = _initializeAi(service);
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    if (widget.debugAiPanel) {
      // UI 调试：不经过抓屏/浮层，直接把窗口配成 AI 面板的尺寸并显示。
      _showAiPage = true;
      unawaited(_presentDebugAiWindow());
    }
  }

  /// 调试用：把“抓屏前的小窗口”直接改成 AI 面板尺寸并显示。
  ///
  /// 正式流程里的窗口尺寸切换在 [_handleAiAction]（先退出浮层再改尺寸）；
  /// 这里窗口从没进过浮层，所以不需要 exitOverlay / setAlwaysOnTop。
  Future<void> _presentDebugAiWindow() async {
    try {
      await _configureAiWindow();
    } on Object catch (error) {
      debugPrint('打开 AI 面板调试窗口失败：$error');
    }
  }

  /// 把窗口配成 AI 面板尺寸并显示。
  ///
  /// debug 入口与正式入口（[_handleAiAction]）共用同一套尺寸/时序；调用方
  /// 负责前置条件与异常处理，这里不吞异常。
  Future<void> _configureAiWindow() async {
    await WidgetsBinding.instance.endOfFrame;
    // 聊天窗口允许拖边缘改大小，但最小就是默认尺寸：默认尺寸是「顶部条 + 消息列表 +
    // 输入栏」刚好放得下的布局，再小就没法用了。
    //
    // 可缩放不能省：macOS 的 styleMask 由 Runner 自己整块赋值
    //（CaptureOverlayWindow.applyPanelAppearance 里是 [.titled, .fullSizeContentView]），
    // 里面没有 .resizable，不插进去的话拖边缘完全没反应。走原生入口是因为插完还得
    // 再藏一遍系统红黄绿按钮（见 enableResizablePanel）。
    // 全屏浮层不受影响：becomeOverlay() 会把 styleMask 换成 [.borderless]。
    await CaptureOverlayWindow.instance.enableResizablePanel();
    // minSize 和 setSize 在 window_manager 里都是窗口 frame，两者取同一个值，
    // 所以“能拖到的下限”正好是默认尺寸。
    await windowManager.setMinimumSize(_aiWindowSize);
    await windowManager.setSize(_aiWindowSize);
    await windowManager.center();
    await showWindow();
    await windowManager.focus();
  }

  Future<void> _initializeAi(HaxAiService service) async {
    try {
      await service.init();
    } on Object catch (error) {
      debugPrint('AI 服务初始化失败：$error');
    }
  }

  @override
  void dispose() {
    if (widget.captureMode) {
      windowManager.removeListener(this);
      _aiController?.dispose();
    }
    super.dispose();
  }

  Future<void> _handleAiAction(HaxAiAction action, Uint8List pngBytes) async {
    final controller = _aiController;
    if (controller == null || _showAiPage) return;

    try {
      // HaxAiController also starts this initialization in onInit. Waiting on
      // the shared service future here prevents an action from observing the
      // initial loading state and losing its screenshot request.
      await _aiInitialization;

      // 先退出浮层状态（层级、collectionBehavior、全屏），再改成 AI 面板的尺寸。
      // 顺序反了的话，一旦 setSize 失败，窗口会停在“全屏 + .screenSaver 层级”，
      // 菜单栏点不到、Esc 也退不出去，整台电脑就没法用了。
      await CaptureOverlayWindow.instance.exitOverlay();
      // 窗口已从 `.screenSaver` 浮层退成普通面板，不再占用捕获独占权；此后用户
      // 可以再次按快捷键开启新的截图，而当前 AI 会话继续保留。
      SingleInstanceGuard.releaseCapture();
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.unmaximize();

      if (!mounted) return;
      // Replace the wide capture toolbar before resizing. On GTK the current
      // child can contribute a minimum width while setSize is processed.
      setState(() => _showAiPage = true);
      await _configureAiWindow();
      unawaited(_sendAiRequest(controller, action, pngBytes));
    } on Object catch (error) {
      // 尤其不能吞掉 exitOverlay 失败：调用方需要恢复截图交互并提示错误，捕获锁
      // 也会因为异常发生在 releaseCapture 之前而继续持有，避免叠出第二层浮层。
      debugPrint('打开 AI 面板失败：$error');
      rethrow;
    }
  }

  Future<void> _sendAiRequest(
    HaxAiController controller,
    HaxAiAction action,
    Uint8List pngBytes,
  ) async {
    try {
      await controller.sendScreenshotAction(action: action, pngBytes: pngBytes);
    } on Object catch (error) {
      debugPrint('AI 请求失败：$error');
    }
  }

  Future<void> _closeCaptureProcess() async {
    if (_allowClose) return;
    _allowClose = true;
    // 给请求文件写一个终态，这样 capture_requests/ 里不会只留下“开始过”的记录，
    // 后面查“这次截图最后怎么了”不用猜。
    final requestId = widget.requestId;
    if (requestId != null) {
      CaptureRequestChannel.instance.writeStateSync(
        requestId,
        CaptureRequestChannel.stateFinished,
      );
      DiagnosticLogService.instance.log(
        DiagnosticEvent.captureFinished,
        requestId: requestId,
      );
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } finally {
      exitProcessNow();
    }
  }

  @override
  void onWindowClose() {
    unawaited(_closeCaptureProcess());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hax Shot',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          // 主题色统一灰蓝，别再回姜黄/浅蓝（见 lib/hax_colors.dart）。
          seedColor: haxAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: widget.captureMode ? _buildCaptureHost() : const TrayHostPage(),
    );
  }

  Widget _buildCaptureHost() {
    final HaxAiController? controller = _aiController;
    if (_showAiPage && controller != null) {
      return AiPage(controller: controller, onClose: _closeCaptureProcess);
    }
    return CapturePage(
      onAiAction: _handleAiAction,
      targetDisplay: widget.targetDisplay,
      requestId: widget.requestId,
    );
  }
}

class TrayHostPage extends StatefulWidget {
  const TrayHostPage({super.key});

  @override
  State<TrayHostPage> createState() => _TrayHostPageState();
}

/// 托盘图标：Windows 的 tray_manager 用 `LoadImage(IMAGE_ICON)` 读取，必须是 .ico；
/// macOS / Linux 都用应用图标 `hax_shot.png`（同一张彩色图）。
String get trayIconAsset => Platform.isWindows
    ? 'assets/icons/hax_shot.ico'
    : 'assets/icons/hax_shot.png';

class _TrayHostPageState extends State<TrayHostPage>
    with TrayListener, WindowListener, WidgetsBindingObserver {
  bool _allowClose = false;
  bool _showShortcutSettings = false;
  bool _showPermissionGuide = false;
  String? _permissionGuideMessage;

  /// 首次启动的欢迎页：托盘/菜单栏应用启动后屏幕上什么都不出现，
  /// 新用户很容易以为没启动（hax_pick 用一次性标记做同样的提示）。
  bool _showFirstRunGuide = false;
  String _firstRunShortcutLabel = '';

  final DiagnosticLogService _diag = DiagnosticLogService.instance;

  /// 截图触发链的唯一入口（快捷键和托盘菜单共用）。
  final CaptureLauncher _captureLauncher = CaptureLauncher();

  /// 托盘菜单是否已经建好；建好之前快捷键状态变化不需要刷新菜单。
  bool _trayReady = false;

  StreamSubscription<String>? _lifecycleEvents;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    // 托盘宿主是常驻进程：全局快捷键在睡眠/唤醒、锁屏/解锁后可能失效，
    // 需要原生生命周期事件把它重新注册回来（见 app_lifecycle_bridge.dart）。
    AppLifecycleBridge.instance.attach();
    _lifecycleEvents = AppLifecycleBridge.instance.events.listen(
      (event) => unawaited(_recoverShortcut(event)),
    );
    shortcutService.registrationStatus.addListener(
      _handleShortcutStatusChanged,
    );
    // 清掉上一次运行留下的请求文件（正在执行的请求刚写过，不会被删）。
    try {
      CaptureRequestChannel.instance.cleanupExpired();
    } on Object catch (error) {
      debugPrint('清理截图请求文件失败：$error');
    }
    unawaited(_initializeDesktopIntegration());
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    shortcutService.registrationStatus.removeListener(
      _handleShortcutStatusChanged,
    );
    unawaited(_lifecycleEvents?.cancel());
    unawaited(trayManager.destroy());
    super.dispose();
  }

  /// Desktop Host 的每一步都有自己的错误边界：窗口、快捷键、托盘、欢迎页互不阻断。
  ///
  /// **快捷键排在托盘前面**：错误隔离不等于卡死隔离。托盘步骤要摸 AppKit 的 status
  /// item，一旦它挂住（拿不到临时 frame、AppIndicator 缺失、Plugin 卡在原生调用里），
  /// 排在后面的快捷键注册就根本不会执行——那正是「按了没反应」的成因之一。Hax Shot
  /// 是截图工具：**快捷键可用 > 菜单栏显示快捷键文字**，托盘菜单可以晚一拍显示状态。
  ///
  /// `--capture` 进程（调试时用）也会走到这里，但它的窗口在 main() 里已经配好，
  /// 这里的 window 步骤是幂等的。
  Future<void> _initializeDesktopIntegration() async {
    _diag.log(DiagnosticEvent.desktopInitStart);
    await _initializeWindowSafely();
    await _initializeShortcutSafely();
    await _initializeTraySafely();
    await _initializeWelcomeSafely();
    _diag.log(DiagnosticEvent.desktopInitComplete);
  }

  Future<void> _initializeWindowSafely() async {
    try {
      await windowManager.setPreventClose(true);
      await windowManager.hide();
      // window_manager 在 runApp 前已经把原生窗口藏起来了，但 Flutter 首帧之前
      // AppKit 的菜单栏布局还没稳定。此时创建 status item 偶尔会先拿到临时 frame，
      // 图标要等下一次窗口活动（例如快捷键截图）才出现；等首帧后再创建可避免这个竞态。
      await WidgetsBinding.instance.endOfFrame;
    } on Object catch (error) {
      _diag.log(
        DiagnosticEvent.windowInitFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.windowInitFailed,
        message: '$error',
      );
    }
  }

  Future<void> _initializeTraySafely() async {
    _diag.log(DiagnosticEvent.trayInitStart);
    try {
      // 不要传 isTemplate: true：那是单色遮罩模式，会把应用图标渲染成纯色剪影。
      // 菜单标签只用内存里的注册状态（activeBinding / configuredBinding），
      // 这里**不读** SharedPreferences：启动关键路径上任何一次无上限的原生读写都可能
      // 把后面的步骤永久挡住（见 MacosShortcutService._preferences 的注释）。
      await trayManager.setIcon(trayIconAsset);
      await trayManager.setContextMenu(_buildTrayMenu());
      _trayReady = true;
      _diag.log(DiagnosticEvent.trayInitSuccess);
    } on Object catch (error) {
      // 缺 AppIndicator 扩展、status item 建不出来都不影响截图：
      // 快捷键注册在 _initializeShortcutSafely() 里独立进行。
      _diag.log(
        DiagnosticEvent.trayInitFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.trayInitFailed,
        message: '$error',
      );
    }
  }

  Future<void> _initializeShortcutSafely() async {
    try {
      await shortcutService.activate(
        onTriggered: () =>
            unawaited(_startCapture(source: CaptureTriggerSource.shortcut)),
      );
    } on Object catch (error) {
      // activate() 设计上不抛异常；真抛了也只是一个模块失败，不能阻断托盘/欢迎页。
      _diag.log(
        DiagnosticEvent.shortcutRegisterFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        message: '$error',
      );
    }
    // 托盘菜单在这之后才建（见 _initializeDesktopIntegration 的顺序），
    // 所以这里不需要刷新；之后的状态变化由 registrationStatus 的 listener 负责。
  }

  Future<void> _initializeWelcomeSafely() async {
    try {
      // 欢迎页最后：即使它失败，图标、菜单和快捷键也已经在上面就绪。
      await _presentFirstRunGuideIfNeeded();
    } on Object catch (error) {
      _diag.log(
        DiagnosticEvent.welcomeInitFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.welcomeInitFailed,
        message: '$error',
      );
    }
  }

  void _handleShortcutStatusChanged() {
    unawaited(_refreshTrayMenu());
  }

  Future<void> _refreshTrayMenu() async {
    if (!_trayReady) return;
    try {
      await trayManager.setContextMenu(_buildTrayMenu());
    } on Object catch (error) {
      debugPrint('刷新托盘菜单失败：$error');
    }
  }

  /// 托盘菜单里那行只读的快捷键状态。
  ///
  /// 显示的是 [ShortcutService.activeBinding]（**系统现在真的会响应哪个组合**），
  /// 而不是偏好设置里的值：写偏好失败时两者会不一致，拿配置当“当前快捷键”会误导人。
  String get _shortcutMenuLabel {
    final status = shortcutService.registrationStatus.value;
    final active = shortcutService.activeBinding;
    final configured = shortcutService.configuredBinding;

    if (active == null) {
      if (configured == null) {
        return status == ShortcutRegistrationStatus.failed
            ? '快捷键：注册失败'
            : '快捷键：未设置';
      }
      return '快捷键：${bindingDisplayLabel(configured)}'
          '（${shortcutStatusLabel(status)}）';
    }

    final label =
        '快捷键：${bindingDisplayLabel(active)}（${shortcutStatusLabel(status)}）';
    if (configured != null && configured != active) {
      // 注册成功但没写进偏好：本次可用，重启会变回配置里的那个。
      return '$label 配置为 ${bindingDisplayLabel(configured)}';
    }
    return label;
  }

  Menu _buildTrayMenu() {
    return Menu(
      items: [
        MenuItem(
          key: 'capture',
          label: '立即截屏',
          onClick: (_) =>
              unawaited(_startCapture(source: CaptureTriggerSource.trayMenu)),
        ),
        MenuItem(
          key: 'shortcut_status',
          label: _shortcutMenuLabel,
          disabled: true,
        ),
        MenuItem(
          key: 'change_shortcut',
          label: '设置',
          onClick: (_) => unawaited(_openShortcutSettings()),
        ),
        // UI 调试入口：debug 构建里把每个界面都单独列出来，不用真的截图/
        // 等授权就能直接打开。发布版不出现。
        if (kDebugMode) ...[
          MenuItem.separator(),
          MenuItem(
            key: 'debug_welcome',
            label: '调试：欢迎页',
            onClick: (_) => unawaited(_presentFirstRunGuide()),
          ),
          MenuItem(
            key: 'debug_shortcut_settings',
            label: '调试：快捷键设置',
            onClick: (_) => unawaited(_openShortcutSettings()),
          ),
          MenuItem(
            key: 'debug_permission_guide',
            label: '调试：权限引导',
            onClick: (_) => unawaited(_openPermissionGuide()),
          ),
          MenuItem(
            key: 'debug_capture_overlay',
            label: '调试：截图浮层',
            onClick: (_) =>
                unawaited(_startCapture(source: CaptureTriggerSource.trayMenu)),
          ),
          MenuItem(
            key: 'debug_ai_panel',
            label: '调试：AI 对话窗口',
            onClick: (_) => unawaited(_openAiPanel()),
          ),
        ],
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: '退出',
          onClick: (_) => unawaited(_quit()),
        ),
      ],
    );
  }

  /// 系统恢复（前台 / 唤醒 / 解锁）后把全局快捷键重新注册回来。
  ///
  /// 统一走 [ShortcutService.reactivate]，它是幂等的并且自己 single-flight：
  /// 唤醒那一刻常常连着收到 wake / resume / unlock 好几个事件，直接重复 register
  /// 会叠出重复 handler 和泄漏的 Carbon token。
  Future<void> _recoverShortcut(String event) async {
    if (!Platform.isMacOS) return;
    _diag.log(event);
    try {
      await shortcutService.reactivate();
    } on Object catch (error) {
      _diag.log(
        DiagnosticEvent.shortcutReactivateFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
        message: '$error',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverShortcut(DiagnosticEvent.appResumed));
    }
  }

  /// 首次启动弹一次欢迎窗口，说明图标在哪、快捷键是什么。
  Future<void> _presentFirstRunGuideIfNeeded() async {
    if (await FirstRunOnboarding.instance.hasSeen()) return;

    // 展示时就记下来，避免用户刚看到就退出、下次启动又弹一次。
    await FirstRunOnboarding.instance.markSeen();
    await _presentFirstRunGuide();
  }

  /// 显示欢迎页。调试入口也会调它，但不会写“已看过”标记。
  Future<void> _presentFirstRunGuide() async {
    final binding = await shortcutService.readBinding();
    if (!mounted) return;

    setState(() {
      _firstRunShortcutLabel = binding == null
          ? ''
          : bindingDisplayLabel(binding);
      _showFirstRunGuide = true;
    });
    await windowManager.setSize(const Size(560, 460));
    await windowManager.center();
    await showWindow();
    await windowManager.focus();
  }

  Future<void> _closeFirstRunGuide() async {
    if (mounted) setState(() => _showFirstRunGuide = false);
    await windowManager.hide();
  }

  Future<void> _openSettingsFromFirstRunGuide() async {
    if (mounted) setState(() => _showFirstRunGuide = false);
    await _openShortcutSettings();
  }

  Future<void> _startCapture({
    CaptureTriggerSource source = CaptureTriggerSource.trayMenu,
  }) async {
    // 菜单和全局快捷键共用这一条链路：requestId → 起子进程 → 等 ACK → 记日志。
    final result = await _captureLauncher.launch(
      source: source,
      displayArguments: _displayArguments(),
    );
    switch (result) {
      case CaptureLaunchStarted():
        break;
      case CaptureLaunchRejected(:final reason):
        // lockBusy 是正常业务状态（已经有一层浮层在等着），不打扰用户。
        debugPrint('本次截图请求未启动：$reason');
      case CaptureLaunchFailed(:final error):
        debugPrint('启动截图失败：$error');
    }
  }

  /// 告诉 `--capture` 进程要抓哪块显示器。
  ///
  /// 用户点菜单的这一刻是唯一能确定“他在哪块屏幕上”的时机，先取一次再传给
  /// 子进程；子进程里的 Rust 和 Swift 都按同一个标识工作。平台不支持时返回空，
  /// 截图进程会用主显示器。
  List<String> _displayArguments() {
    try {
      final display = NativeBridge.instance.cursorDisplay();
      if (display == 0) return const [];
      return ['--display', '$display'];
    } on Object catch (error) {
      debugPrint('读取当前显示器失败：$error');
      return const [];
    }
  }

  /// 调试入口：直接打开 AI 对话窗口（跳过抓屏与浮层）。
  ///
  /// AI 面板在正式流程里属于 `--capture` 进程，所以这里同样起一个子进程，只是多带
  /// 上 `--debug-ai` 让它在启动时就把窗口显示成 AI 面板。
  Future<void> _openAiPanel() async {
    try {
      await Process.start(Platform.resolvedExecutable, [
        '--capture',
        '--debug-ai',
      ], mode: ProcessStartMode.detached);
    } on Object catch (error) {
      debugPrint('打开 AI 对话窗口失败：$error');
    }
  }

  /// 调试入口：直接打开授权引导页调 UI（不影响真实的权限状态）。
  Future<void> _openPermissionGuide() async {
    if (!mounted) return;
    setState(() {
      _showPermissionGuide = true;
      _showShortcutSettings = false;
      _permissionGuideMessage = null;
    });
    // 和捕获进程的窗口尺寸保持一致（见 lib/main.dart）：授权引导要一屏放得下。
    await windowManager.setSize(const Size(560, 480));
    await windowManager.center();
    await showWindow();
    await windowManager.focus();
  }

  /// 引导页里的“我已授权，重新检查”：调试时只反馈当前真实状态。
  Future<void> _checkPermissionForGuide() async {
    final authorized = NativeBridge.instance.screenCaptureAuthorized();
    if (!mounted) return;
    setState(
      () => _permissionGuideMessage = authorized
          ? '调试：当前进程已获得屏幕录制权限。'
          : '调试：当前进程还没有屏幕录制权限。真实截图时会走到这个页面。',
    );
  }

  /// 调试入口里的“重置授权记录”：清掉记录并说明下一步。
  Future<void> _resetPermissionForGuide() async {
    await ScreenCapturePermission.instance.reset();
    if (!mounted) return;
    setState(
      () =>
          _permissionGuideMessage = '调试：已清掉旧的授权记录。下次从菜单栏“立即截屏”或按快捷键时会重新弹出授权请求。',
    );
  }

  Future<void> _closePermissionGuide() async {
    if (mounted) setState(() => _showPermissionGuide = false);
    await windowManager.hide();
  }

  Future<void> _openShortcutSettings() async {
    if (!mounted) return;
    setState(() => _showShortcutSettings = true);
    await windowManager.setSize(const Size(520, 400));
    await windowManager.center();
    await showWindow();
    await windowManager.focus();
  }

  Future<void> _closeShortcutSettings() async {
    if (mounted) setState(() => _showShortcutSettings = false);
    await windowManager.hide();
  }

  Future<void> _quit() async {
    if (_allowClose) return;
    _allowClose = true;
    try {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      // GTK can close the hidden window without terminating the
      // GtkApplication event loop. Force-destroy it, then end the tray host.
      await windowManager.destroy();
    } finally {
      // 最后才放锁：放出太早会让下一份实例在快捷键还没注销完的时候启动。
      SingleInstanceGuard.release();
      exitProcessNow();
    }
  }

  @override
  void onTrayIconMouseDown() => _popUpTrayMenu();

  @override
  void onTrayIconRightMouseDown() => _popUpTrayMenu();

  /// macOS 的 tray_manager 在 `setContextMenu` 里只是把菜单存起来，菜单只在
  /// `popUpContextMenu()` 里才挂到 status item 上（菜单关掉后又摘下来），所以必须
  /// 自己处理图标点击，否则点菜单栏图标什么都不发生。Linux 的 AppIndicator 会
  /// 自己弹菜单，不能重复调用。
  void _popUpTrayMenu() {
    if (!Platform.isMacOS) return;
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onWindowClose() {
    if (_allowClose) return;
    if (_showFirstRunGuide) {
      unawaited(_closeFirstRunGuide());
      return;
    }
    if (_showPermissionGuide) {
      unawaited(_closePermissionGuide());
      return;
    }
    unawaited(_closeShortcutSettings());
  }

  @override
  Widget build(BuildContext context) {
    // Hax Shot is tray-only. The short-lived --capture process owns the
    // full-screen selection UI; this host only reveals shortcut settings on
    // demand.
    if (_showPermissionGuide) {
      return CapturePermissionGuide(
        message: _permissionGuideMessage,
        onRetry: _checkPermissionForGuide,
        onQuit: _closePermissionGuide,
        onResetPermission: Platform.isMacOS ? _resetPermissionForGuide : null,
      );
    }
    if (_showFirstRunGuide) {
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            unawaited(_closeFirstRunGuide());
          },
        },
        child: Focus(
          autofocus: true,
          child: FirstRunGuide(
            shortcutLabel: _firstRunShortcutLabel,
            onOpenSettings: () => unawaited(_openSettingsFromFirstRunGuide()),
            onClose: () => unawaited(_closeFirstRunGuide()),
          ),
        ),
      );
    }
    if (_showShortcutSettings) {
      return ShortcutSettingsPage(onClose: _closeShortcutSettings);
    }
    return const SizedBox.shrink();
  }
}
