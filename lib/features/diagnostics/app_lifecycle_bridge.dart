import 'dart:async';

import 'package:flutter/services.dart';

import 'diagnostic_events.dart';

/// macOS 原生生命周期事件（睡眠唤醒 / 锁屏解锁）→ Dart 的最小桥。
///
/// 为什么不能只靠 `AppLifecycleState.resumed`：托盘宿主是 `LSUIElement` 隐藏窗口应用，
/// 屏幕锁定 / 显示器睡眠时它不一定收到 `applicationDidBecomeActive`，于是 Carbon 全局
/// 热键失效后没有任何机会重新注册——表现就是“睡一觉起来快捷键没反应了”。
///
/// 原生侧只负责把事件名发过来（`macos/Runner/MainFlutterWindow.swift` 的
/// `SystemLifecycleBridge`），快捷键状态仍然由 Dart 的 ShortcutService 统一管理。
final class AppLifecycleBridge {
  AppLifecycleBridge._();

  static final instance = AppLifecycleBridge._();

  static const _channel = MethodChannel('hax_shot/lifecycle');

  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  bool _attached = false;

  /// 原生生命周期事件流，值是 [DiagnosticEvent] 里的 `macos_*` 常量。
  Stream<String> get events => _controller.stream;

  /// 注册通道处理器。重复调用无副作用（只有一个 handler 能挂在 MethodChannel 上）。
  void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'lifecycle') return null;
      final Object? argument = call.arguments;
      if (argument is String && argument.isNotEmpty) {
        _controller.add(argument);
      }
      return null;
    });
  }

  /// 测试用：直接投递一个事件，不经过原生通道。
  void debugEmit(String event) => _controller.add(event);
}
