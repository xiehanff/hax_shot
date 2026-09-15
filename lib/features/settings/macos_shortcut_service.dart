import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';
import 'hotkey_binding.dart';
import 'macos_shortcut_bridge.dart';
import 'shortcut_registration.dart';
import 'shortcut_service.dart';

/// macOS 全局快捷键：注册状态机 + 真实 Carbon 注册结果。
///
/// 原生层是 `macos/Runner/ShortcutBridge.swift`（直接调 Carbon），**不是**
/// `hotkey_manager_macos`：那个插件的 Swift 端在 `register()` 里无条件 `result(true)`，
/// 而 soffes/HotKey 内部的 `RegisterEventHotKey` 失败时静默 `return`。用它的话，
/// 「Carbon 没注册上」和「注册成功」在 Dart 侧完全一样，正是要消灭的那种故障。
///
/// 这个类只负责**注册状态机**：注册 / 注销 / 幂等重注册 / 改绑事务与回滚 / 状态上报。
/// 它不关心快捷键按下之后干什么（那是 `onTriggered` 回调的事）。
final class MacosShortcutService implements ShortcutService {
  MacosShortcutService({
    Future<void> Function(HotKey hotKey, void Function() onTriggered)?
    registerHotKey,
    Future<void> Function(HotKey hotKey)? unregisterHotKey,
    DiagnosticLogService? log,
    this.preferenceTimeout = const Duration(seconds: 2),
    this.retryDelay = const Duration(milliseconds: 250),
    this.reactivateMergeWindow = const Duration(seconds: 1),
  }) : _registerHotKey = registerHotKey ?? _defaultRegister,
       _unregisterHotKey = unregisterHotKey ?? _defaultUnregister,
       _log = log ?? DiagnosticLogService.instance;

  static final instance = MacosShortcutService();

  static const bindingKey = 'hax_shot.capture_shortcut';

  /// 首次启动时使用的默认快捷键。
  ///
  /// 菜单栏图标可能被 Bartender 这类菜单栏管理工具收进隐藏区，所以截图工具必须有
  /// 一个不依赖图标的入口；用户可以在设置页随时改掉它。
  static const defaultBinding = '<Alt><Shift>z';

  /// 历史上自动写入过的默认值；启动时迁移到当前默认值。只命中这两个值，用户自己
  /// 在设置页录制的组合键不会被改掉。
  static const _legacyDefaultBindings = {'<Alt>z', '<Super><Shift>z'};

  /// 读取/写入偏好设置的上限。
  ///
  /// `SharedPreferences` 底层是原生 `NSUserDefaults`；正常情况下一瞬间就返回，但它
  /// 会卡住时**永远不会**返回：偏好 plist 被 `rm` 直接删掉（而不是用 `defaults delete`）
  /// 后，cfprefsd 会留着坏掉的 domain，下一次启动的读写就吊在那里。菜单栏图标可能被
  /// Bartender 这类工具藏起来，快捷键是唯一的兜底入口，所以这里必须给它一个上限：
  /// 宁可退回内置默认值，也不能因为偏好层故障就没有快捷键。
  final Duration preferenceTimeout;

  /// 启动注册失败后的有限重试间隔（最多重试一次，不做无限重试）。
  final Duration retryDelay;

  /// 唤醒/解锁/前台恢复常常在几百毫秒内连着来；这个窗口内的重注册直接复用上次结果。
  final Duration reactivateMergeWindow;

  final Future<void> Function(HotKey hotKey, void Function() onTriggered)
  _registerHotKey;
  final Future<void> Function(HotKey hotKey) _unregisterHotKey;
  final DiagnosticLogService _log;

  final ValueNotifier<ShortcutRegistrationStatus> _status =
      ValueNotifier<ShortcutRegistrationStatus>(
        ShortcutRegistrationStatus.inactive,
      );

  HotKey? _registered;
  void Function()? _onTriggered;
  String? _activeBinding;
  String? _configuredBinding;
  Object? _lastError;
  DateTime? _lastRegisteredAt;
  Future<ShortcutActivationResult>? _reactivationInFlight;

  /// 所有会改变注册状态的操作都排进这条队列，避免 activate / reactivate /
  /// saveBinding / clearBinding 互相穿插出重复注册。
  Future<void> _operationQueue = Future<void>.value();

  @override
  ShortcutRegistrationStatus get status => _status.value;

  @override
  String? get activeBinding => _activeBinding;

  @override
  Object? get lastError => _lastError;

  @override
  DateTime? get lastRegisteredAt => _lastRegisteredAt;

  @override
  ValueListenable<ShortcutRegistrationStatus> get registrationStatus => _status;

  /// 最近一次从偏好设置读到的绑定（= 持久化配置），和 [activeBinding] 分开看。
  @override
  String? get configuredBinding => _configuredBinding;

  /// 走自建原生桥：Carbon 的 OSStatus 会真的传回来，失败就抛。
  static Future<void> _defaultRegister(
    HotKey hotKey,
    void Function() onTriggered,
  ) async {
    final keyCode = carbonKeyCodeFromHotKey(hotKey);
    if (keyCode == null) {
      throw FormatException('macOS 上没有这个按键的 Carbon 键码：${hotKey.debugName}');
    }
    final result = await MacosShortcutBridge.instance.register(
      keyCode: keyCode,
      modifiers: modifierNamesFromHotKey(hotKey),
      onTriggered: onTriggered,
    );
    if (!result.ok) {
      throw ShortcutNativeException('注册', result);
    }
  }

  static Future<void> _defaultUnregister(HotKey hotKey) async {
    final result = await MacosShortcutBridge.instance.unregister();
    if (!result.ok) {
      throw ShortcutNativeException('注销', result);
    }
  }

  /// 把会改变注册状态的操作用一条队列串起来，同一时刻只有一个在跑。
  ///
  /// 只包住对外的入口（activate / reactivate / saveBinding / clearBinding），
  /// 不能包 `_tryRegister` / `_unregisterInternal`，否则会自己等自己。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationQueue = _operationQueue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Future<ShortcutActivationResult> activate({
    required void Function() onTriggered,
  }) {
    _onTriggered = onTriggered;
    // 读绑定 + 注册也要排队：生命周期事件可能在 `readBinding()` 还没返回时就调
    // `reactivate()`，两条路径同时注销/注册会叠出重复 handler。
    return _serialized(() async {
      final binding = await _resolveBinding();
      return _registerWithRetry(binding);
    });
  }

  @override
  Future<ShortcutActivationResult> reactivate() {
    final existing = _reactivationInFlight;
    if (existing != null) return existing;
    late Future<ShortcutActivationResult> future;
    future = _serialized(_doReactivate).whenComplete(() {
      if (identical(_reactivationInFlight, future)) {
        _reactivationInFlight = null;
      }
    });
    _reactivationInFlight = future;
    return future;
  }

  Future<ShortcutActivationResult> _doReactivate() async {
    if (_onTriggered == null) {
      // 还没 activate 过（启动竞态）：这不是“注册失败”，不能把状态改成 failed，
      // 否则托盘会短暂显示一个不存在的故障。
      final error = StateError('快捷键服务还没有激活');
      _log.log(
        DiagnosticEvent.shortcutReactivateFailed,
        level: LogLevel.warning,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
        message: '$error',
      );
      return ShortcutActivationFailure(
        binding: _activeBinding ?? _configuredBinding ?? defaultBinding,
        error: error,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
      );
    }

    final binding =
        _activeBinding ?? _configuredBinding ?? await _resolveBinding();

    // 合并窗口：系统唤醒时会连着收到 wake / resume / unlock 多个事件，不能重复注册。
    final lastRegisteredAt = _lastRegisteredAt;
    if (_status.value == ShortcutRegistrationStatus.active &&
        _activeBinding == binding &&
        lastRegisteredAt != null &&
        DateTime.now().difference(lastRegisteredAt) < reactivateMergeWindow) {
      return ShortcutActivationSuccess(binding: binding);
    }

    _log.log(
      DiagnosticEvent.shortcutReactivateStart,
      extra: <String, Object?>{'binding': binding},
    );
    // 幂等：先把旧的注册清掉，保证内部状态回到“未注册”，再重新注册。
    _activeBinding = null;
    final unregisterError = await _unregisterInternal();
    if (unregisterError != null) {
      // 注销没成功就不能接着注册：旧 Carbon handler 还活着，再注册一个新的会变成
      // 两个 handler 一起触发截图。状态也不能停在 active——它已经不成立了。
      _lastError = unregisterError;
      _setStatus(ShortcutRegistrationStatus.failed);
      _log.log(
        DiagnosticEvent.shortcutReactivateFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
        message: '重新注册前注销旧快捷键失败：$unregisterError',
        extra: <String, Object?>{'binding': binding},
      );
      return ShortcutActivationFailure(
        binding: binding,
        error: unregisterError,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
      );
    }
    final result = await _registerWithRetry(binding);
    if (result.isSuccess) {
      _log.log(
        DiagnosticEvent.shortcutReactivateSuccess,
        extra: <String, Object?>{'binding': binding},
      );
    } else {
      _log.log(
        DiagnosticEvent.shortcutReactivateFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.shortcutReactivateFailed,
        message: '${(result as ShortcutActivationFailure).error}',
        extra: <String, Object?>{'binding': binding},
      );
    }
    return result;
  }

  @override
  Future<ShortcutActivationResult> saveBinding(String binding) {
    return _serialized(() async {
      final previous = _activeBinding;
      if (_onTriggered == null) {
        final error = StateError('快捷键服务还没有激活');
        _lastError = error;
        _setStatus(ShortcutRegistrationStatus.failed);
        return ShortcutActivationFailure(
          binding: binding,
          error: error,
          errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        );
      }

      // 事务顺序：注销旧 → 注册新 → 成功才落盘；失败尝试回滚旧绑定。
      // 详见 docs/development-guide.md「快捷键改绑事务」。
      // 先清掉“已注册”的标记：从这一刻起旧绑定确实不再注册了，
      // activeBinding 必须反映“当前真的注册了什么”，而不是“配置里写了什么”。
      // 真正的注销在 _tryRegister 里做（它在注销失败时会中止，不会留下两个 handler）。
      _activeBinding = null;
      final result = await _tryRegister(binding);
      if (result.isSuccess) {
        try {
          await _writeBinding(binding).timeout(preferenceTimeout);
          _configuredBinding = binding;
        } on Object catch (error) {
          // 注册已经成功（本次确实可用），只是没记住；重启后会回到旧配置，
          // 所以不能报「完全成功」，要把 persisted: false 交给 UI。
          _log.log(
            DiagnosticEvent.shortcutPreferenceWriteFailed,
            level: LogLevel.warning,
            errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
            message: '$error',
          );
          return ShortcutActivationSuccess(binding: binding, persisted: false);
        }
        return result;
      }

      final failure = result as ShortcutActivationFailure;
      if (previous == null || previous == binding) {
        return failure;
      }

      // 回滚：把旧绑定重新注册回去，成功则状态回到 active、偏好设置保持旧值。
      final restored = await _tryRegister(previous, logRegisterEvents: false);
      if (restored.isSuccess) {
        _configuredBinding = previous;
        _log.log(
          DiagnosticEvent.shortcutRestoreSuccess,
          level: LogLevel.warning,
          errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
          message: '新快捷键注册失败，已恢复旧快捷键',
          extra: <String, Object?>{
            'failed_binding': binding,
            'restored_binding': previous,
          },
        );
        return ShortcutActivationFailure(
          binding: binding,
          error: failure.error,
          errorCode: failure.errorCode,
          restoredBinding: previous,
        );
      }

      // 回滚也失败：快捷键当前完全不可用，UI 必须明确显示。
      _log.log(
        DiagnosticEvent.shortcutRestoreFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.shortcutRestoreFailed,
        message: '新快捷键与旧快捷键都注册失败',
        extra: <String, Object?>{
          'failed_binding': binding,
          'restore_binding': previous,
        },
      );
      return ShortcutActivationFailure(
        binding: binding,
        error: failure.error,
        errorCode: DiagnosticErrorCode.shortcutRestoreFailed,
        rollbackFailed: true,
      );
    });
  }

  /// 返回 false 表示**没有清掉**（注销失败或偏好没删成），UI 不能报“已删除”。
  @override
  Future<bool> clearBinding() {
    return _serialized(() async {
      final error = await _unregisterInternal();
      if (error != null) {
        // 注销失败还留着旧注册，这时删偏好设置会变成「配置里没有、系统里还活着」。
        _lastError = error;
        _setStatus(ShortcutRegistrationStatus.failed);
        _log.log(
          DiagnosticEvent.shortcutUnregister,
          level: LogLevel.error,
          errorCode: DiagnosticErrorCode.shortcutUnregisterFailed,
          message: '注销失败，快捷键没有被清除：$error',
        );
        return false;
      }
      _activeBinding = null;
      _setStatus(ShortcutRegistrationStatus.inactive);
      try {
        final preferences = await _preferences();
        await preferences.remove(bindingKey);
      } on Object catch (error) {
        // 注册已经撤掉，只是配置没删；下次启动会把它再注册回来。
        _lastError = error;
        _log.log(
          DiagnosticEvent.shortcutPreferenceWriteFailed,
          level: LogLevel.error,
          errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
          message: '删除快捷键配置失败：$error',
        );
        return false;
      }
      _configuredBinding = null;
      return true;
    });
  }

  /// 读偏好设置也必须有上限。
  ///
  /// `SharedPreferences` 底层是 `NSUserDefaults`，坏掉的 domain（plist 被 `rm` 删掉）
  /// 会让它**永远不返回**。启动链上任何一次无上限的读取都可能把后面的步骤（尤其是
  /// 快捷键注册）永久挡住，所以所有读写统一走 [_preferences]。
  Future<SharedPreferences> _preferences() =>
      SharedPreferences.getInstance().timeout(preferenceTimeout);

  @override
  Future<String?> readBinding() async {
    final preferences = await _preferences();
    final binding = preferences.getString(bindingKey);
    final value = (binding == null || binding.isEmpty) ? null : binding;
    _configuredBinding = value;
    return value;
  }

  /// 注册失败时最多再试一次：有限重试能吃掉偶发的瞬时故障，无限重试会掩盖真正的 bug。
  Future<ShortcutActivationResult> _registerWithRetry(
    String binding, {
    bool allowRetry = true,
  }) async {
    final first = await _tryRegister(binding);
    if (first.isSuccess || !allowRetry) return first;
    _log.log(
      DiagnosticEvent.shortcutRegisterFailed,
      level: LogLevel.warning,
      errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
      message: '首次注册失败，${retryDelay.inMilliseconds}ms 后重试一次',
      extra: <String, Object?>{'binding': binding, 'attempt': 1},
    );
    await Future<void>.delayed(retryDelay);
    return _tryRegister(binding, attempt: 2);
  }

  Future<ShortcutActivationResult> _tryRegister(
    String binding, {
    int attempt = 1,
    bool logRegisterEvents = true,
  }) async {
    _setStatus(ShortcutRegistrationStatus.registering);
    if (logRegisterEvents) {
      _log.log(
        DiagnosticEvent.shortcutRegisterStart,
        extra: <String, Object?>{'binding': binding, 'attempt': attempt},
      );
    }

    final hotKey = hotKeyFromBinding(binding);
    if (hotKey == null) {
      return _fail(
        binding,
        FormatException('macOS 不支持这个按键：$binding'),
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }

    // 先把当前注册清掉，再注册新的：hotkey_manager 的 macOS 端按 identifier 存
    // HotKey，不清掉会让 Dart 侧 `_hotKeyList` 堆同一个 identifier 的重复项。
    // 注销失败必须中止：继续注册会留下两个活的 Carbon handler。
    final unregisterError = await _unregisterInternal(logEvent: false);
    if (unregisterError != null) {
      return _fail(
        binding,
        unregisterError,
        errorCode: DiagnosticErrorCode.shortcutUnregisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }

    try {
      await _registerHotKey(hotKey, _onTriggered ?? () {});
    } on Object catch (error) {
      return _fail(
        binding,
        error,
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }

    _registered = hotKey;
    _activeBinding = binding;
    _configuredBinding = binding;
    _lastError = null;
    _lastRegisteredAt = DateTime.now();
    _setStatus(ShortcutRegistrationStatus.active);
    if (logRegisterEvents) {
      _log.log(
        DiagnosticEvent.shortcutRegisterSuccess,
        extra: <String, Object?>{'binding': binding, 'attempt': attempt},
      );
    }
    return ShortcutActivationSuccess(binding: binding);
  }

  ShortcutActivationFailure _fail(
    String binding,
    Object error, {
    required String errorCode,
    bool logRegisterEvent = true,
  }) {
    _lastError = error;
    _setStatus(ShortcutRegistrationStatus.failed);
    if (logRegisterEvent) {
      _log.log(
        DiagnosticEvent.shortcutRegisterFailed,
        level: LogLevel.error,
        errorCode: errorCode,
        message: '$error',
        extra: <String, Object?>{
          'binding': binding,
          // Carbon 的真实返回值：查“注册了却没反应”时按它过滤最直接。
          if (error is ShortcutNativeException) 'os_status': error.osStatus,
        },
      );
    }
    return ShortcutActivationFailure(
      binding: binding,
      error: error,
      errorCode: errorCode,
    );
  }

  /// 注销当前注册；返回 null 表示成功（或本来就没有注册），非 null 是失败原因。
  ///
  /// 失败时必须保留 `_registered`，这样后面的重试还能再注销一次；调用方也必须
  /// 中止后续注册，否则旧的 Carbon handler 和新注册的会同时活着。
  Future<Object?> _unregisterInternal({bool logEvent = true}) async {
    final current = _registered;
    if (current == null) return null;
    try {
      await _unregisterHotKey(current);
    } on Object catch (error) {
      _log.log(
        DiagnosticEvent.shortcutUnregister,
        level: LogLevel.warning,
        errorCode: DiagnosticErrorCode.shortcutUnregisterFailed,
        message: '注销全局快捷键失败：$error',
        extra: <String, Object?>{
          if (error is ShortcutNativeException) 'os_status': error.osStatus,
        },
      );
      return error;
    }
    _registered = null;
    if (logEvent) {
      _log.log(DiagnosticEvent.shortcutUnregister);
    }
    return null;
  }

  /// 读出当前绑定；任何失败都退回内置默认值，保证首次注册一定能拿到一个组合。
  Future<String> _resolveBinding() async {
    try {
      final binding = await readBinding().timeout(preferenceTimeout);
      if (binding != null && !_legacyDefaultBindings.contains(binding)) {
        _configuredBinding = binding;
        return binding;
      }
      final migrated = binding != null;
      _configuredBinding = defaultBinding;
      try {
        await _writeBinding(defaultBinding).timeout(preferenceTimeout);
        _log.log(
          DiagnosticEvent.shortcutPreferenceMigrated,
          message: migrated
              ? '已把旧默认快捷键迁移为 $defaultBinding'
              : '首次启动，使用默认全局快捷键 $defaultBinding',
        );
      } on Object catch (error) {
        // 写不进去只影响下次启动能不能记住，不影响本次注册。
        _log.log(
          DiagnosticEvent.shortcutPreferenceWriteFailed,
          level: LogLevel.warning,
          errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
          message: '保存默认快捷键失败（仍然注册）：$error',
        );
      }
      return defaultBinding;
    } on Object catch (error) {
      _configuredBinding = defaultBinding;
      _log.log(
        DiagnosticEvent.shortcutPreferenceReadFailed,
        level: LogLevel.warning,
        errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
        message: '读取快捷键设置失败，改用默认值：$error',
      );
      return defaultBinding;
    }
  }

  Future<void> _writeBinding(String binding) async {
    final preferences = await _preferences();
    await preferences.setString(bindingKey, binding);
  }

  void _setStatus(ShortcutRegistrationStatus value) {
    if (_status.value == value) return;
    _status.value = value;
  }
}
