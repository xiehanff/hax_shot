import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// 显示窗口前的统一入口。
///
/// macOS 的 Runner 启动时把窗口设成 `alphaValue = 0`：nib 会在启动阶段就把窗口排到
/// 最前，而这时 Flutter 还没画出第一帧，用户会看到一个小黑窗口闪一下（托盘宿主和
/// 捕获进程都会）。窗口可见性完全由 Dart 控制，所以显示前在这里恢复不透明度。
///
/// 只有 macOS 需要这一步：`window_manager` 0.5.2 的 Windows 实现里 `setOpacity`
/// **无条件**给窗口加 `WS_EX_LAYERED`（`window_manager_plugin.cpp` 的 `SetOpacity`），
/// 而 Windows 的冻结画面浮层必须保持普通（非分层）窗口——分层窗口会参与 DWM 合成，
/// 残影、拖动和 topmost 组合都会出问题（§14.7）。Linux 没有别的调用点依赖“显示前
/// 恢复 opacity”，也一起跳过，避免同样的副作用。
Future<void> showWindow() async {
  if (Platform.isMacOS) {
    await windowManager.setOpacity(1);
  }
  await windowManager.show();
}
