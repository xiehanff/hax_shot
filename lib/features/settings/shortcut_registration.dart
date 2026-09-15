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
