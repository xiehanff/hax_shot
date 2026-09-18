/// 全局快捷键的注册状态。
///
/// 「配置里存着某个组合」和「系统当前真的注册了这个组合」是两件事，以前被混为
/// 一谈：读取配置成功就当成快捷键可用，注册失败只在 `debugPrint` 里留一行。
/// 这个枚举把两者拆开，调用方（托盘菜单 / 设置页）必须按 [active] 判断可用性。
enum ShortcutRegistrationStatus {
  /// 没有绑定，或已被显式清除。
  inactive,

  /// 正在注册（含重新注册）。
  registering,

  /// 注册调用成功，当前认为可用。
  active,

  /// 注册失败；[ShortcutService.lastError] 里有原因。
  failed,
}

/// [ShortcutRegistrationStatus] 的中文展示文案（托盘菜单和设置页共用）。
String shortcutStatusLabel(ShortcutRegistrationStatus status) =>
    switch (status) {
      ShortcutRegistrationStatus.inactive => '未启用',
      ShortcutRegistrationStatus.registering => '注册中…',
      ShortcutRegistrationStatus.active => '已启用',
      ShortcutRegistrationStatus.failed => '注册失败',
    };

/// 一次注册/改绑尝试的结果。调用方必须靠它决定 UI 与是否回滚，不能只看异常。
sealed class ShortcutActivationResult {
  const ShortcutActivationResult({
    required this.binding,
    this.persisted = true,
  });

  /// 本次尝试的目标绑定。
  final String binding;

  /// false 表示“本次已经生效，但没能写进偏好设置，重启后会恢复旧配置”。
  final bool persisted;

  bool get isSuccess => this is ShortcutActivationSuccess;
}

final class ShortcutActivationSuccess extends ShortcutActivationResult {
  const ShortcutActivationSuccess({required super.binding, super.persisted});
}

/// 注册失败。
///
/// [restoredBinding] 非空表示已经成功把旧绑定注册回去（改绑事务回滚成功）；
/// 为空且 [rollbackFailed] 为 true 表示新绑定和旧绑定都注册不上，快捷键当前不可用。
final class ShortcutActivationFailure extends ShortcutActivationResult {
  const ShortcutActivationFailure({
    required super.binding,
    required this.error,
    this.errorCode,
    this.restoredBinding,
    this.rollbackFailed = false,
  });

  final Object error;
  final String? errorCode;
  final String? restoredBinding;
  final bool rollbackFailed;
}

/// 一次原生注册/注销的结果，带**真实**的原生错误码。
///
/// 这正是 `hotkey_manager_*` 拿不到的东西：它的原生端在 register 里无条件
/// `result(true)`，所以 Dart 侧分不清「系统注册成功」和「静默失败」。这里把
/// 原生返回值原样带回来。
///
/// [osStatus] 字段名沿用的是 macOS 桥的协议（§21：Windows 复用同一形状，
/// 不改字段名）：macOS 放 Carbon 的 `OSStatus`，Windows 放 `GetLastError()`
/// 或桥自有 code（0 表示成功）。
final class ShortcutNativeResult {
  const ShortcutNativeResult({
    required this.ok,
    required this.osStatus,
    this.message,
  });

  /// 原生调用是否成功。
  final bool ok;

  /// 原生返回值，0 表示成功（macOS：OSStatus；Windows：Win32 错误码）。
  final int osStatus;

  /// 原生侧给出的可读原因（会进诊断日志）。
  final String? message;

  @override
  String toString() => ok
      ? 'ok(osStatus=0)'
      : '原生错误码 $osStatus${message == null ? '' : '：$message'}';
}

/// 原生注册/注销失败。带上原生错误码和可读原因，供日志与设置页展示。
final class ShortcutNativeException implements Exception {
  const ShortcutNativeException(this.action, this.result);

  final String action;
  final ShortcutNativeResult result;

  /// 日志里的 `nativeCode`（§56.2）：macOS 是 Carbon OSStatus，Windows 是 Win32 错误码。
  int get osStatus => result.osStatus;

  @override
  String toString() =>
      '$action失败（${result.message ?? '系统拒绝了这个组合'}，'
      '原生错误码 ${result.osStatus}）';
}
