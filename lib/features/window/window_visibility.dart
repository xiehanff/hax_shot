import 'package:window_manager/window_manager.dart';

/// 显示窗口前的统一入口。
///
/// macOS 的 Runner 启动时把窗口设成 `alphaValue = 0`：nib 会在启动阶段就把窗口排到
/// 最前，而这时 Flutter 还没画出第一帧，用户会看到一个小黑窗口闪一下（托盘宿主和
/// 捕获进程都会）。窗口可见性完全由 Dart 控制，所以显示前在这里恢复不透明度。
/// 其它平台 `setOpacity(1)` 就是默认值，没有副作用。
Future<void> showWindow() async {
  await windowManager.setOpacity(1);
  await windowManager.show();
}
