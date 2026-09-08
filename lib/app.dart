import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/ai/controllers/hax_ai_controller.dart';
import 'features/ai/models/hax_ai_action.dart';
import 'features/ai/services/hax_ai_service.dart';
import 'features/ai/services/hax_ai_settings_store.dart';
import 'features/ai/views/ai_page.dart';
import 'features/capture/capture_page.dart';
import 'features/settings/shortcut_settings_page.dart';

class HaxShotApp extends StatefulWidget {
  const HaxShotApp({required this.captureMode, super.key});

  final bool captureMode;

  @override
  State<HaxShotApp> createState() => _HaxShotAppState();
}

class _HaxShotAppState extends State<HaxShotApp> with WindowListener {
  // Match Plume's 6px resize handle + 320px sidebar layout.
  static const Size _aiWindowSize = Size(456, 896);

  HaxAiController? _aiController;
  Future<void>? _aiInitialization;
  bool _showAiPage = false;
  bool _ignoreNextWindowClose = false;
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

      // CapturePage must be allowed to close the transient capture overlay
      // immediately. The conversation continues on the same Flutter page.
      if (aiPageShown) {
        _ignoreNextWindowClose = true;
        unawaited(_sendAiRequest(controller, action, pngBytes));
      }
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
    if (_ignoreNextWindowClose) {
      _ignoreNextWindowClose = false;
      return;
    }
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
    return CapturePage(onAiAction: _handleAiAction);
  }
}

class TrayHostPage extends StatefulWidget {
  const TrayHostPage({super.key});

  @override
  State<TrayHostPage> createState() => _TrayHostPageState();
}

class _TrayHostPageState extends State<TrayHostPage>
    with TrayListener, WindowListener {
  bool _allowClose = false;
  bool _showShortcutSettings = false;

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
      await trayManager.setIcon('assets/icons/hax_shot.png');
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
            MenuItem.separator(),
            MenuItem(
              key: 'exit_app',
              label: '退出',
              onClick: (_) => unawaited(_quit()),
            ),
          ],
        ),
      );
    } on Object catch (error) {
      // A missing AppIndicator extension should not prevent screenshots.
      debugPrint('Hax Shot tray initialization failed: $error');
    }
  }

  Future<void> _startCapture() async {
    try {
      await Process.start(Platform.resolvedExecutable, const [
        '--capture',
      ], mode: ProcessStartMode.detached);
    } on Object catch (error) {
      debugPrint('启动截图失败：$error');
    }
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
  void onWindowClose() {
    if (!_allowClose) {
      unawaited(_closeShortcutSettings());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hax Shot is tray-only. The short-lived --capture process owns the
    // full-screen selection UI; this host only reveals shortcut settings on
    // demand.
    if (_showShortcutSettings) {
      return ShortcutSettingsPage(onClose: _closeShortcutSettings);
    }
    return const SizedBox.shrink();
  }
}
