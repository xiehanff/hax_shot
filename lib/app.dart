import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/ai/controllers/hax_ai_controller.dart';
import 'features/ai/models/hax_ai_action.dart';
import 'features/ai/services/hax_ai_service.dart';
import 'features/ai/services/hax_ai_settings_store.dart';
import 'features/ai/views/ai_page.dart';
import 'features/capture/capture_overlay_window.dart';
import 'features/capture/capture_page.dart';
import 'features/capture/capture_permission_guide.dart';
import 'features/onboarding/first_run_guide.dart';
import 'features/onboarding/first_run_onboarding.dart';
import 'features/settings/screen_capture_permission.dart';
import 'features/settings/shortcut_service.dart';
import 'features/settings/shortcut_settings_page.dart';
import 'native/native_bridge.dart';

class HaxShotApp extends StatefulWidget {
  const HaxShotApp({required this.captureMode, this.targetDisplay, super.key});

  final bool captureMode;

  /// `--display <id>`：主浮层要落在哪块显示器（重启抓屏进程时原样带上）。
  final int? targetDisplay;

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
    _aiController = Get.put(HaxAiController(service: service));
    _aiInitialization = _initializeAi(service);
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
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
      if (Get.isRegistered<HaxAiController>()) {
        unawaited(Get.delete<HaxAiController>(force: true));
      }
    }
    super.dispose();
  }

  Future<void> _handleAiAction(HaxAiAction action, Uint8List pngBytes) async {
    final controller = _aiController;
    if (controller == null || _showAiPage) return;
    var aiPageShown = false;

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
      await WidgetsBinding.instance.endOfFrame;
      await windowManager.setMinimumSize(const Size(320, 480));
      await windowManager.setSize(_aiWindowSize);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      aiPageShown = true;
      unawaited(_sendAiRequest(controller, action, pngBytes));
    } on Object catch (error) {
      // Keep the AI page visible even if initialization or the first request
      // fails; the sidebar can still be used to configure the API key.
      debugPrint('AI 请求失败：$error');
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
      exit(0);
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
          seedColor: Colors.lightBlue,
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

/// 托盘图标：Windows 的 tray_manager 用 LoadImage(IMAGE_ICON) 读取，必须是 .ico；
/// Linux AppIndicator 和 macOS 菜单栏用 PNG。
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
      await trayManager.setIcon(trayIconAsset);
      // macOS 由这个常驻进程注册全局快捷键，按下时走和托盘菜单一样的启动流程；
      // GNOME 侧快捷键由 gsettings 直接启动子进程，这个回调不会被用到。
      await shortcutService.activate(
        onTriggered: () => unawaited(_startCapture()),
      );
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
            // 调试期方便反复调授权引导的 UI，发布版不出现。
            if (kDebugMode)
              MenuItem(
                key: 'debug_permission_guide',
                label: '权限引导（调试）',
                onClick: (_) => unawaited(_openPermissionGuide()),
              ),
            MenuItem.separator(),
            MenuItem(
              key: 'exit_app',
              label: '退出',
              onClick: (_) => unawaited(_quit()),
            ),
          ],
        ),
      );
      // 托盘菜单先建好：即使欢迎页失败，用户也有入口。
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
    await windowManager.show();
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

  /// 调试入口：直接打开授权引导页调 UI（不影响真实的权限状态）。
  Future<void> _openPermissionGuide() async {
    if (!mounted) return;
    setState(() {
      _showPermissionGuide = true;
      _showShortcutSettings = false;
      _permissionGuideMessage = null;
    });
    await windowManager.setSize(const Size(560, 400));
    await windowManager.center();
    await windowManager.show();
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
    await windowManager.show();
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
      exit(0);
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
