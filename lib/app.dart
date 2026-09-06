import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'features/capture/capture_page.dart';
import 'features/settings/shortcut_settings_page.dart';

class HaxShotApp extends StatelessWidget {
  const HaxShotApp({required this.captureMode, super.key});

  final bool captureMode;

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
      home: captureMode ? const CapturePage() : const TrayHostPage(),
    );
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
      await trayManager.setTitle('Hax Shot');
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
              label: '修改快捷键',
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
