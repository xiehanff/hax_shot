import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 把捕获进程的窗口升格成冻结画面浮层。
///
/// 捕获进程启动时只是一个普通小窗口，抓屏失败时用户看到的是小窗口里的提示；
/// 只有抓到画面之后才调用 [becomeOverlay] 铺满目标显示器。
final class CaptureOverlayWindow {
  CaptureOverlayWindow({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('hax_shot/capture_window'),
      _enabled = enabled ?? (Platform.isMacOS && !kIsWeb);

  static final instance = CaptureOverlayWindow();

  final MethodChannel _channel;
  final bool _enabled;

  /// 退出浮层状态：恢复普通窗口层级并关掉全屏。
  ///
  /// AI 面板接管同一个窗口之前必须走这里，否则窗口可能停在
  /// “全屏 + .screenSaver 层级”——菜单栏点不到、Esc 也退不出去。
  Future<void> exitOverlay() async {
    if (_enabled) {
      try {
        await _channel.invokeMethod<void>('exitOverlay');
        return;
      } on Object catch (error) {
        debugPrint('退出浮层失败：$error');
      }
    }
    await windowManager.setFullScreen(false);
  }

  /// 让窗口盖住菜单栏和 Dock（macOS 由 Runner 设置窗口层级）。
  Future<void> becomeOverlay() async {
    if (_enabled) {
      try {
        await _channel.invokeMethod<void>('becomeOverlay');
        return;
      } on Object catch (error) {
        debugPrint('切换浮层失败：$error');
      }
    }
    // 其它平台用 Flutter 自己的全屏（窗口此时仍然隐藏，等 show() 才出现）。
    await windowManager.setFullScreen(true);
  }
}
