import 'package:flutter/services.dart';

/// 一次原生注册/注销的结果，带**真实**的 Carbon OSStatus。
///
/// 这正是 `hotkey_manager_macos` 拿不到的东西：它的 Swift 端无条件 `result(true)`，
/// 所以 Dart 侧分不清「Carbon 注册成功」和「静默失败」。这里把 OSStatus 原样带回来。
final class ShortcutNativeResult {
  const ShortcutNativeResult({
    required this.ok,
    required this.osStatus,
    this.message,
  });

  /// 原生调用是否成功（OSStatus == noErr）。
  final bool ok;

  /// `RegisterEventHotKey` / `UnregisterEventHotKey` 的原始返回值，0 表示成功。
  final int osStatus;

  /// 原生侧给出的可读原因（会进诊断日志）。
  final String? message;

  @override
  String toString() => ok
      ? 'ok(osStatus=0)'
      : 'OSStatus $osStatus${message == null ? '' : '：$message'}';
}

/// macOS 全局快捷键原生桥（`macos/Runner/ShortcutBridge.swift`）。
///
/// 只负责三件事：register / unregister 透传 OSStatus，以及把按键触发转成回调。
/// 注册状态机、改绑事务、回滚都在 [MacosShortcutService] 里，不在这里。
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

/// 原生注册/注销失败。带上 OSStatus 和可读原因，供日志与设置页展示。
final class ShortcutNativeException implements Exception {
  const ShortcutNativeException(this.action, this.result);

  final String action;
  final ShortcutNativeResult result;

  int get osStatus => result.osStatus;

  @override
  String toString() =>
      '$action失败（${result.message ?? 'Carbon 拒绝了这个组合'}，'
      'OSStatus ${result.osStatus}）';
}
