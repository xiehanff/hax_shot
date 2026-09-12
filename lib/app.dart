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
import 'features/capture/capture_overlay_window.dart';
import 'features/capture/capture_page.dart';
import 'features/capture/capture_permission_guide.dart';
import 'features/onboarding/first_run_guide.dart';
import 'features/onboarding/first_run_onboarding.dart';
import 'features/settings/screen_capture_permission.dart';
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
    super.key,
  });

  final bool captureMode;

  /// `--display <id>`：主浮层要落在哪块显示器（重启抓屏进程时原样带上）。
  final int? targetDisplay;

  /// debug 构建的 `--capture --debug-ai`：不抓屏，直接把窗口显示成 AI 面板。
  final bool debugAiPanel;

  @override
  State<HaxShotApp> createState() => _HaxShotAppState();
}

class _HaxShotAppState extends State<HaxShotApp> with WindowListener {
  // 宽度沿用 Plume 的侧栏比例（456 = 6px 把手 + 320 侧栏的观感），高度刻意留矮
  // 一点，别占满整块屏。
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
    await windowManager.setMinimumSize(const Size(320, 480));
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
      // Keep the AI page visible even if the window setup fails; the sidebar
      // can still be used to configure the API key.
      // 请求失败的日志在 _sendAiRequest 里，这里只管窗口/面板准备。
      debugPrint('打开 AI 面板失败：$error');
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
    with TrayListener, WindowListener {
  bool _allowClose = false;
  bool _showShortcutSettings = false;
  bool _showPermissionGuide = false;
  String? _permissionGuideMessage;

  /// 首次启动的欢迎页：托盘/菜单栏应用启动后屏幕上什么都不出现，
  /// 新用户很容易以为没启动（hax_pick 用一次性标记做同样的提示）。
  bool _showFirstRunGuide = false;
  String _firstRunShortcutLabel = '';

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    unawaited(_initializeDesktopIntegration());
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    unawaited(trayManager.destroy());
    super.dispose();
  }

  Future<void> _initializeDesktopIntegration() async {
    try {
      await windowManager.setPreventClose(true);
      await windowManager.hide();
      // window_manager 在 runApp 前已经把原生窗口藏起来了，但 Flutter 首帧之前
      // AppKit 的菜单栏布局还没稳定。此时创建 status item 偶尔会先拿到临时 frame，
      // 图标要等下一次窗口活动（例如快捷键截图）才出现；等首帧后再创建可避免这个竞态。
      await WidgetsBinding.instance.endOfFrame;
      // 图标和菜单是用户看到的第一样东西，先建好再做别的：注册快捷键要读
      // SharedPreferences、走一次 Carbon，欢迎页还要读磁盘，都会拖慢“图标出现”。
      // 不要传 isTemplate: true：那是单色遮罩模式，会把应用图标渲染成纯色剪影。
      await trayManager.setIcon(trayIconAsset);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              key: 'capture',
              label: '立即截屏',
              onClick: (_) => unawaited(_startCapture()),
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
                onClick: (_) => unawaited(_startCapture()),
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
        ),
      );
      // macOS 由这个常驻进程注册全局快捷键，按下时走和托盘菜单一样的启动流程；
      // GNOME 侧快捷键由 gsettings 直接启动子进程，这个回调不会被用到。
      await shortcutService.activate(
        onTriggered: () => unawaited(_startCapture()),
      );
      // 欢迎页最后：即使它失败，图标和菜单也已经在上面建好了。
      await _presentFirstRunGuideIfNeeded();
    } on Object catch (error) {
      // A missing AppIndicator extension should not prevent screenshots.
      debugPrint('Hax Shot tray initialization failed: $error');
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

  Future<void> _startCapture() async {
    try {
      await Process.start(Platform.resolvedExecutable, [
        '--capture',
        ..._displayArguments(),
      ], mode: ProcessStartMode.detached);
    } on Object catch (error) {
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
