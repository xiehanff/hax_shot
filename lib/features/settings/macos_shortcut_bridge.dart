import 'package:flutter/services.dart';

import 'shortcut_registration.dart';

/// macOS 全局快捷键原生桥（`macos/Runner/ShortcutBridge.swift`）。
///
/// 只负责三件事：register / unregister 透传 OSStatus，以及把按键触发转成回调。
/// 注册状态机、改绑事务、回滚都在 [MacosShortcutService] 里，不在这里。
///
/// [ShortcutNativeResult] / [ShortcutNativeException] 两个结果类型已经搬到
/// `shortcut_registration.dart`：Windows 桥复用同一份解析与日志字段（§21）。
final class MacosShortcutBridge {
  MacosShortcutBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'hax_shot/shortcut';

  static final instance = MacosShortcutBridge();

  final MethodChannel _channel;

  void Function()? _onTriggered;
  bool _attached = false;

  /// 注册全局快捷键。[keyCode] 是 **Carbon 虚拟键码（kVK_*）**，
  /// [modifiers] 是 `alt` / `control` / `shift` / `meta`（Super 即 Command）。
  Future<ShortcutNativeResult> register({
    required int keyCode,
    required List<String> modifiers,
    required void Function() onTriggered,
  }) async {
    _onTriggered = onTriggered;
    _attach();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'register',
      {'keyCode': keyCode, 'modifiers': modifiers},
    );
    return _parse(result);
  }

  Future<ShortcutNativeResult> unregister() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'unregister',
    );
    return _parse(result);
  }

  /// 每个进程只允许一个 handler；重复设置在测试里也只是覆盖回调。
  void _attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'triggered') return null;
      _onTriggered?.call();
      return null;
    });
  }

  ShortcutNativeResult _parse(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return const ShortcutNativeResult(
        ok: false,
        osStatus: -1,
        message: '原生桥没有返回结果',
      );
    }
    final ok = raw['ok'];
    final osStatus = raw['osStatus'];
    final message = raw['message'];
    return ShortcutNativeResult(
      ok: ok == true,
      osStatus: osStatus is int ? osStatus : -1,
      message: message is String ? message : null,
    );
  }
}
