import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'features/app/hard_exit.dart';
import 'features/app/single_instance_guard.dart';

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
  if (!captureMode && !SingleInstanceGuard.acquire()) {
    // 托盘宿主必须唯一：否则会出现“退出了一份，另一份还握着全局快捷键”。
    // 放这里（而不是 runApp 之后）：拿不到锁就直接退出，用户看不到任何窗口。
    stderr.writeln('已有 Hax Shot 在运行，本次启动退出');
    exitProcessNow();
  }
  final targetDisplay = _targetDisplay(args);
  // macOS 的浮层由 Runner 的 CaptureOverlayWindow 直接改窗口（borderless +
  // .screenSaver + 铺满目标显示器），不走 window_manager：setAlwaysOnTop 会把
  // 层级改回 .normal/.floating，setTitleBarStyle 又会在 borderless 窗口上强解包
  // nil 崩溃。所以 macOS 捕获模式不传这三个选项。详见 docs/development-guide.md 6.9。
  final nativeCaptureOverlay = captureMode && Platform.isMacOS;
  final options = WindowOptions(
    title: 'Hax Shot',
    // Linux 的窗口没有原生圆角：Dart 侧用 RoundedWindow 裁一刀，窗口背景必须透明，
    // 否则被裁掉的四角会露出 window_manager 写进 GTK CSS 的那层背景色（看起来就是
    // “有圆角但角外是方块”）。macOS 的圆角由系统的 titled 窗口画，窗口保持不透明黑。
    // 详见 docs/development-guide.md 的“窗口圆角”。
    backgroundColor: Platform.isLinux ? Colors.transparent : Colors.black,
    // The tray host only reveals the shortcut settings page on demand; keep
    // that temporary window compact instead of inheriting a full-screen size.
    // 捕获进程先只用一个小窗口：抓屏失败（没授权等）时用户看到的是引导，
    // 抓到画面之后才由 CaptureOverlayWindow / setFullScreen 升格成全屏浮层。
    size: captureMode ? const Size(560, 400) : const Size(520, 400),
    minimumSize: captureMode ? const Size(460, 320) : const Size(460, 320),
    center: true,
    // The product is tray-only; neither the hidden host nor the transient
    // selection overlay belongs in the Dock/taskbar.
    skipTaskbar: true,
    // 抓屏成功前不要全屏：失败时要留一个能正常关闭的小窗口。
    alwaysOnTop: nativeCaptureOverlay ? null : false,
    fullScreen: null,
    // The settings view supplies its own Flutter AppBar; the tray host should
    // not expose a second native title bar, and the macOS traffic lights would
    // sit on top of our close button.
    titleBarStyle: nativeCaptureOverlay ? null : TitleBarStyle.hidden,
    windowButtonVisibility: false,
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

  runApp(HaxShotApp(captureMode: captureMode, targetDisplay: targetDisplay));
}

/// 托盘宿主用 `--display <id>` 指定主浮层落在哪块显示器；授权后重启抓屏进程时
/// 需要原样带上。id 是平台自己的显示器标识，Flutter 只负责转交。
int? _targetDisplay(List<String> args) {
  final index = args.indexOf('--display');
  if (index < 0 || index + 1 >= args.length) return null;
  final value = int.tryParse(args[index + 1]);
  return (value == null || value == 0) ? null : value;
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
