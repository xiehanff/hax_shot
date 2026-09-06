import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final captureMode = args.contains('--capture');
  final options = WindowOptions(
    title: 'Hax Shot',
    backgroundColor: Colors.black,
    // The tray host only reveals the shortcut settings page on demand; keep
    // that temporary window compact instead of inheriting a full-screen size.
    size: captureMode ? null : const Size(520, 400),
    minimumSize: captureMode ? null : const Size(460, 320),
    center: !captureMode,
    // The product is tray-only; neither the hidden host nor the transient
    // selection overlay belongs in the Dock/taskbar.
    skipTaskbar: true,
    alwaysOnTop: captureMode,
    fullScreen: captureMode,
    // The settings view supplies its own Flutter AppBar; the tray host and
    // capture overlay should not expose a second native title bar.
    titleBarStyle: TitleBarStyle.hidden,
  );

  // The regular process is tray-only. A capture process stays hidden until
  // the native ScreenCast frame has been prepared, so the overlay never gets
  // captured into its own background.
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.hide();
  });

  runApp(HaxShotApp(captureMode: captureMode));
}
