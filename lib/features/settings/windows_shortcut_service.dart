import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';
import 'hotkey_binding.dart';
import 'shortcut_registration.dart';
import 'shortcut_service.dart';

/// Windows 全局快捷键原生桥（`windows/runner/windows_shortcut_bridge.cpp`）。
///
/// 只做三件事：register / unregister 透传真实 Win32 错误码，以及把按键触发转成回调。
/// 注册状态机、改绑事务、回滚都在 [WindowsShortcutService] 里。
///
/// channel 名与返回形状（`{ok, osStatus, message}`）和 macOS 桥完全一致（§21），
/// 但 keyCode 的含义**不同**：这里是 Windows 虚拟键码（`VK_*`）。刻意分成两个类，
/// 不共用 macOS 那个：把 Carbon 键码和 VK 混在一条路径上是 §25.2 明确禁止的。
final class WindowsShortcutBridge {
  WindowsShortcutBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'hax_shot/shortcut';

  static final instance = WindowsShortcutBridge();

  final MethodChannel _channel;

  void Function()? _onTriggered;
  bool _attached = false;

  /// 注册全局快捷键。
  ///
  /// [virtualKeyCode] 是 **Windows 虚拟键码（VK_*）**，[modifiers] 是
  /// `alt` / `control` / `shift` / `meta` 四个名字里的若干个（`meta` 即 Win 键）。
  /// 原生层会自己补 `MOD_NOREPEAT`，并检查 `RegisterHotKey` 的返回值。
  Future<ShortcutNativeResult> register({
    required int virtualKeyCode,
    required List<String> modifiers,
    required void Function() onTriggered,
  }) async {
    _onTriggered = onTriggered;
    _attach();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'register',
      {'keyCode': virtualKeyCode, 'modifiers': modifiers},
    );
    final parsed = _parse(result);
    if (!parsed.ok) {
      // 注册失败时原生不会投递 triggered（`RegisterHotKey` 没成功），但桥上不能继续
      // 挂着一个已经无效的回调：留着它没有任何用处，清掉更符合“没注册就没有触发”（§23）。
      _onTriggered = null;
    }
    return parsed;
  }

  Future<ShortcutNativeResult> unregister() async {
    // 先把回调摘掉再调原生：native -> Dart 的 `triggered` 是异步投递的，用户刚点
    // “删除快捷键”时队列里可能还有一条已发出的触发消息。注销成功后它必须变成
    // 无操作，否则用户删了快捷键仍会启动一次截图（§23）。
    final void Function()? previous = _onTriggered;
    _onTriggered = null;
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'unregister',
    );
    final parsed = _parse(result);
    if (!parsed.ok) {
      // 注销失败说明系统里可能还注册着：恢复回调，避免“按了没反应”的二次伤害。
      _onTriggered = previous;
    }
    return parsed;
  }

  /// 每个进程只允许一个 handler；重复设置只是覆盖回调。
  ///
  /// handler 本身不解绑：解绑后再注册要重建 handler，而回调的有效性由
  /// `_onTriggered` 控制（注销/失败时置空，注册时重新赋值），见 [unregister]。
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

// TODO(shortcut-state-machine): 下面的状态机是 `macos_shortcut_service.dart` 的复制
// （§24.4 允许本轮复制，但要求写清差异，后续再合并）。与 macOS 的差异只有三处：
//
//   1. 绑定 → 键码用 `windowsVirtualKeyCode()`（Windows VK），不是 Carbon 键码；
//   2. 偏好语义：删除时写哨兵 `''` 跨重启保持禁用，且**没有** macOS 的
//      `_legacyDefaultBindings` 默认值迁移分支（§24.3）；
//   3. `configured` 只在持久化真的成功之后才更新，`_tryRegister` 不碰它（§24.2）。
//
// 合并的前置条件是 macOS 侧能靠 CI 做真实验证，本轮不做。

/// Windows 全局快捷键：注册状态机 + 真实 `RegisterHotKey` 结果。
///
/// 原生层是 `windows/runner/windows_shortcut_bridge.cpp`，**不是**
/// `hotkey_manager_windows`：那个插件的 C++ 端把 `RegisterHotKey` 的返回值丢掉、
/// 然后无条件 `result->Success(true)`（§20）。用它的话，「系统拒绝了这个组合」和
/// 「注册成功」在 Dart 侧完全一样，正是要消灭的那种故障。
///
/// 这个类只负责**注册状态机**：注册 / 注销 / 幂等重注册 / 改绑事务与回滚 / 状态上报。
/// 快捷键按下之后干什么（`onTriggered` → `CaptureLauncher`）不在这里，
/// 原生层也不会直接起截图进程（§21）。
final class WindowsShortcutService implements ShortcutService {
  WindowsShortcutService({
    Future<void> Function(
      int virtualKeyCode,
      List<String> modifiers,
      void Function() onTriggered,
    )?
    registerHotKey,
    Future<void> Function()? unregisterHotKey,
    DiagnosticLogService? log,
    this.preferenceTimeout = const Duration(seconds: 2),
    this.retryDelay = const Duration(milliseconds: 250),
    this.reactivateMergeWindow = const Duration(seconds: 1),
  }) : _registerHotKey = registerHotKey ?? _defaultRegister,
       _unregisterHotKey = unregisterHotKey ?? _defaultUnregister,
       _log = log ?? DiagnosticLogService.instance;

  static final instance = WindowsShortcutService();

  /// 与 macOS 用同一个偏好键名（各平台各自的偏好存储，不会互相覆盖）。
  static const bindingKey = 'hax_shot.capture_shortcut';

  /// 首次启动（偏好里没有值）时使用的默认快捷键，与 macOS/Linux 保持一致。
  static const defaultBinding = '<Alt><Shift>z';

  /// 哨兵：用户**明确删除过**快捷键（§24.3）。
  ///
  /// 必须和“偏好键不存在”区分开：前者是“不要再注册”，后者是“首次使用，用默认值”。
  /// macOS 现在把两者混在一起（删了偏好下次启动又建默认值），Windows 不继承这个行为。
  static const disabledSentinel = '';

  /// 读偏好设置的上限：偏好层坏掉时不能把启动链上的注册步骤永久挡住。
  final Duration preferenceTimeout;

  /// 启动注册失败后的有限重试间隔（最多重试一次，不做无限重试）。
  final Duration retryDelay;

  /// `resumed` / 唤醒类事件常常在几百毫秒内连着来；这个窗口内的重注册直接复用上次结果。
  final Duration reactivateMergeWindow;

  final Future<void> Function(
    int virtualKeyCode,
    List<String> modifiers,
    void Function() onTriggered,
  )
  _registerHotKey;
  final Future<void> Function() _unregisterHotKey;
  final DiagnosticLogService _log;

  final ValueNotifier<ShortcutRegistrationStatus> _status =
      ValueNotifier<ShortcutRegistrationStatus>(
        ShortcutRegistrationStatus.inactive,
      );

  /// 原生层当前是否真的注册着（`RegisterHotKey` 返回 TRUE 才置位）。
  bool _registered = false;
  void Function()? _onTriggered;
  String? _activeBinding;
  String? _configuredBinding;
  Object? _lastError;
  DateTime? _lastRegisteredAt;
  Future<ShortcutActivationResult>? _reactivationInFlight;

  /// 用户明确禁用过（偏好里是哨兵）。禁用状态下 `reactivate()` 不做任何事（§24.3）。
  bool _disabled = false;

  /// 所有会改变注册状态的操作都排进这条队列，避免 activate / reactivate /
  /// saveBinding / clearBinding 互相穿插出重复注册。
  Future<void> _operationQueue = Future<void>.value();

  @override
  ShortcutRegistrationStatus get status => _status.value;

  @override
  String? get activeBinding => _activeBinding;

  @override
  String? get configuredBinding => _configuredBinding;

  @override
  Object? get lastError => _lastError;

  @override
  DateTime? get lastRegisteredAt => _lastRegisteredAt;

  @override
  ValueListenable<ShortcutRegistrationStatus> get registrationStatus => _status;

  /// 走自建原生桥：`RegisterHotKey` 失败时把真实 `GetLastError()` 抛回来。
  static Future<void> _defaultRegister(
    int virtualKeyCode,
    List<String> modifiers,
    void Function() onTriggered,
  ) async {
    final result = await WindowsShortcutBridge.instance.register(
      virtualKeyCode: virtualKeyCode,
      modifiers: modifiers,
      onTriggered: onTriggered,
    );
    if (!result.ok) {
      throw ShortcutNativeException('注册', result);
    }
  }

  static Future<void> _defaultUnregister() async {
    final result = await WindowsShortcutBridge.instance.unregister();
    if (!result.ok) {
      throw ShortcutNativeException('注销', result);
    }
  }

  /// 把会改变注册状态的操作用一条队列串起来，同一时刻只有一个在跑。
  ///
  /// 只包住对外入口（activate / reactivate / saveBinding / clearBinding），
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
    // 读绑定 + 注册也要排队：生命周期事件可能在偏好还没读完时就调 `reactivate()`。
    return _serialized(() async {
      final binding = await _resolveBindingForRegistration();
      if (binding == null) {
        // 用户删过绑定：本次启动不注册，也不写偏好（§24.3）。
        _activeBinding = null;
        _setStatus(ShortcutRegistrationStatus.inactive);
        _log.log(
          DiagnosticEvent.shortcutUnregister,
          message: '快捷键已被用户删除（偏好里是空值），本次启动不注册',
        );
        return const ShortcutActivationFailure(
          binding: disabledSentinel,
          error: '快捷键已被用户删除，本次启动不注册',
        );
      }
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

    if (_disabled) {
      // 用户删过绑定：这里什么都不做，也不标成 failed——“没有快捷键”是用户要的状态。
      return const ShortcutActivationFailure(
        binding: disabledSentinel,
        error: '快捷键已被用户删除，不重新注册',
      );
    }

    final binding = _activeBinding ?? _configuredBinding ?? defaultBinding;

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
    // 幂等：先把旧的注册清掉，保证原生状态回到“未注册”，再重新注册。
    _activeBinding = null;
    final unregisterError = await _unregisterInternal();
    if (unregisterError != null) {
      // 注销没成功就不能接着注册：旧注册可能还活着，再注册一个新的会变成两个热键。
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

  /// 改绑事务：先注册新绑定、成功才写偏好；注册失败则回滚旧绑定。
  ///
  /// 顺序与 macOS 相反（§24.2）：那边是「先改 `configured` 再注册/写盘」，写失败时
  /// `configured` 已经是新值，于是“已生效但没存”和“已存但没生效”分不出来。
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

      // 先清掉“已注册”的标记：从这一刻起旧绑定不再算数。真正的注销在 _tryRegister
      // 里做（它在注销失败时会中止，不会留下两个热键）。
      _activeBinding = null;
      final result = await _tryRegister(binding);
      if (result.isSuccess) {
        try {
          await _writeBinding(binding).timeout(preferenceTimeout);
        } on Object catch (error) {
          // 已经生效，只是没存下来：`configured` 保持旧值，UI 要显示
          // “本次已生效但未保存，重启后会恢复旧绑定”（§24.2 第 4 步）。
          _log.log(
            DiagnosticEvent.shortcutPreferenceWriteFailed,
            level: LogLevel.warning,
            errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
            message: '$error',
          );
          return ShortcutActivationSuccess(binding: binding, persisted: false);
        }
        // 只有写盘成功才更新 configured；同时清掉“已禁用”标记。
        _configuredBinding = binding;
        _disabled = false;
        return result;
      }

      final failure = result as ShortcutActivationFailure;
      if (previous == null || previous == binding) {
        return failure;
      }

      // 回滚：把旧绑定重新注册回去，成功则状态回到 active、偏好设置保持旧值。
      final restored = await _tryRegister(previous, logRegisterEvents: false);
      if (restored.isSuccess) {
        // 偏好里还是旧值，`_configuredBinding` 不用动——改绑失败时不能顺手把
        // “没存过”的值写成“已配置”（首次启动的默认值就没存过）。
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

  /// 返回 false 表示**没有清掉**（注销失败或哨兵没写成功），UI 不能报“已删除”。
  @override
  Future<bool> clearBinding() {
    return _serialized(() async {
      final error = await _unregisterInternal();
      if (error != null) {
        // 注销失败还留着旧注册，这时写哨兵会变成“配置里没有、系统里还占着”。
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
        // 写哨兵（不是删键）：删键等于“首次使用”，下次启动又会建默认值（§24.3）。
        await _writeBinding(disabledSentinel).timeout(preferenceTimeout);
      } on Object catch (error) {
        // 注册已经撤掉，只是哨兵没写进去；`configured` 保持偏好里的旧值不动，
        // 下次启动会把那个旧绑定再注册回来。
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
      _disabled = true;
      return true;
    });
  }

  /// 读偏好设置也必须有上限：偏好层坏掉时不能把启动链上的注册步骤永久挡住。
  Future<SharedPreferences> _preferences() =>
      SharedPreferences.getInstance().timeout(preferenceTimeout);

  /// 偏好里的原始值：`null` = 没配过（首次使用），`''` = 用户明确删除（§24.3）。
  Future<String?> _readRawBinding() async {
    final preferences = await _preferences();
    return preferences.getString(bindingKey);
  }

  @override
  Future<String?> readBinding() async {
    final raw = await _readRawBinding();
    final value = (raw == null || raw == disabledSentinel) ? null : raw;
    _configuredBinding = value;
    return value;
  }

  /// 本次启动要注册的绑定；`null` 表示“用户明确禁用，不注册”。
  Future<String?> _resolveBindingForRegistration() async {
    final String? stored;
    try {
      stored = await _readRawBinding();
    } on Object catch (error) {
      // 读失败只降级本次注册：不写默认值、不抹掉用户意图（§24.3）。
      _log.log(
        DiagnosticEvent.shortcutPreferenceReadFailed,
        level: LogLevel.warning,
        errorCode: DiagnosticErrorCode.shortcutPreferenceFailed,
        message: '读取快捷键设置失败，本次按默认值 $defaultBinding 注册（不写回）：$error',
      );
      return defaultBinding;
    }
    if (stored == disabledSentinel) {
      _disabled = true;
      _configuredBinding = null;
      return null;
    }
    if (stored == null) {
      // 首次使用：用默认值注册，但**不写偏好**——保持“未配置”，
      // 这样“用户没配过”和“用户明确禁用”不会在磁盘上混为一谈（§24.3）。
      _configuredBinding = null;
      return defaultBinding;
    }
    _disabled = false;
    _configuredBinding = stored;
    return stored;
  }

  Future<void> _writeBinding(String binding) async {
    final preferences = await _preferences();
    await preferences.setString(bindingKey, binding);
  }

  /// 注册失败时最多再试一次：吃掉“上一个实例刚退出、组合还没释放”这类瞬时故障。
  /// 不做无限重试——`RegisterHotKey` 的失败原因基本都是确定性的（组合被占用 /
  /// 系统保留），无限重试只会把真问题刷掉。
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

    // 至少一个修饰键的要求沿用 hotKeyFromBinding 的规则（返回 null 即不合格），
    // 没有修饰键的全局热键会把单个按键从所有程序手里抢走。
    final hotKey = hotKeyFromBinding(binding);
    if (hotKey == null) {
      return _fail(
        binding,
        FormatException('Windows 不支持这个组合：$binding'),
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }
    final virtualKeyCode = windowsVirtualKeyCode(binding);
    if (virtualKeyCode == null) {
      return _fail(
        binding,
        FormatException(windowsVirtualKeyRejection(binding)),
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }
    final modifiers = modifierNamesFromHotKey(hotKey);

    // 同一个 HWND/id 的旧注册不会自动替换，必须先真注销（§22）。
    // 注销失败必须中止：继续注册会留下两个活着的热键。
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
      await _registerHotKey(virtualKeyCode, modifiers, _onTriggered ?? () {});
    } on Object catch (error) {
      return _fail(
        binding,
        error,
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        logRegisterEvent: logRegisterEvents,
      );
    }

    _registered = true;
    _activeBinding = binding;
    _lastError = null;
    _lastRegisteredAt = DateTime.now();
    _setStatus(ShortcutRegistrationStatus.active);
    if (logRegisterEvents) {
      _log.log(
        DiagnosticEvent.shortcutRegisterSuccess,
        extra: <String, Object?>{
          'binding': binding,
          'attempt': attempt,
          // 真正发给 RegisterHotKey 的 VK：排查“注对了没”不用猜映射（§25）。
          'virtual_key_code': virtualKeyCode,
          'nativeCode': 0,
        },
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
          // 真实的原生返回值：1409 = ERROR_HOTKEY_ALREADY_REGISTERED。
          // 诊断日志的字段名沿用 nativeCode（§56.2），值就是 osStatus。
          if (error is ShortcutNativeException) 'nativeCode': error.osStatus,
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
  /// 中止后续注册，否则旧热键和新注册的会同时活着。
  Future<Object?> _unregisterInternal({bool logEvent = true}) async {
    if (!_registered) return null;
    try {
      await _unregisterHotKey();
    } on Object catch (error) {
      _log.log(
        DiagnosticEvent.shortcutUnregister,
        level: LogLevel.warning,
        errorCode: DiagnosticErrorCode.shortcutUnregisterFailed,
        message: '注销全局快捷键失败：$error',
        extra: <String, Object?>{
          if (error is ShortcutNativeException) 'nativeCode': error.osStatus,
        },
      );
      return error;
    }
    _registered = false;
    if (logEvent) {
      _log.log(DiagnosticEvent.shortcutUnregister);
    }
    return null;
  }

  void _setStatus(ShortcutRegistrationStatus value) {
    if (_status.value == value) return;
    _status.value = value;
  }
}
