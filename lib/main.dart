import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(_writeErrorLog(details.exception, details.stack));
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    unawaited(_writeErrorLog(details.exception, details.stack));
    return _ErrorDetailsView(details: details);
  };
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
  // Configure the native window first, then hide it synchronously. Passing an
  // async callback to waitUntilReadyToShow is unsafe because window_manager
  // invokes VoidCallback without awaiting it; the later capture show() could
  // otherwise race with this initial hide().
  await windowManager.waitUntilReadyToShow(options);
  await windowManager.hide();

  runApp(HaxShotApp(captureMode: captureMode));
}

class _ErrorDetailsView extends StatelessWidget {
  const _ErrorDetailsView({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF8B0000),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Text(
          '${details.exception}\n\n${details.stack ?? ''}',
          style: const TextStyle(color: Colors.yellow, fontSize: 14),
        ),
      ),
    );
  }
}

Future<void> _writeErrorLog(Object error, StackTrace? stackTrace) async {
  try {
    final File file = File('/tmp/hax_shot_error.log');
    await file.writeAsString(
      '${DateTime.now().toIso8601String()}\n$error\n'
      '${stackTrace ?? StackTrace.current}\n\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Error logging must never affect the application error path.
  }
}
