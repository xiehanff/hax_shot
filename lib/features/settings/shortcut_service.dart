import 'dart:io';

import 'package:flutter/foundation.dart';

import 'gnome_shortcut_service.dart';
import 'macos_shortcut_service.dart';
import 'shortcut_registration.dart';

/// 截图快捷键的平台接口。
///
/// 绑定字符串在三个桌面平台共用同一种格式，例如 `<Super><Shift>z`：
/// Linux 直接写进 GNOME gsettings，macOS 交给原生层转换成 Carbon 全局热键。
abstract interface class ShortcutService {
  /// 宿主启动时接管已保存的快捷键。
  ///
  /// GNOME 由系统自己维护 gsettings 里的自定义快捷键（按一下就启动 `--capture`
  /// 子进程），因此 Linux 实现忽略 [onTriggered]；macOS 必须在托盘宿主进程里注册
  /// 全局热键，按下时调用 [onTriggered] 启动截图。
  ///
  /// **不抛异常**：注册失败通过返回值 + [status] 上报，调用方必须检查结果。
  /// 快捷键注册失败不能阻断 Desktop Host 的其它初始化步骤。
  Future<ShortcutActivationResult> activate({
    required void Function() onTriggered,
  });

  /// 幂等地重新注册当前绑定（唤醒 / 解锁 / 前台恢复后调用）。
  ///
  /// 决不允许直接再调一次 [activate]：那会叠出重复 handler 和泄漏的 Carbon token。
  /// 实现内部必须 single-flight，同一时刻只有一个重注册在飞。
  Future<ShortcutActivationResult> reactivate();

  /// 改绑事务：先注销旧绑定、注册新绑定，成功才持久化；失败则回滚旧绑定。
  ///
  /// 返回失败时 [activeBinding] 要么是旧值（回滚成功），要么为空且 [status] 为
  /// [ShortcutRegistrationStatus.failed]（回滚也失败）。
  Future<ShortcutActivationResult> saveBinding(String binding);

  Future<String?> readBinding();

  /// 清除快捷键。返回 false 表示**没有清掉**（注销失败或配置没删成），
  /// UI 不能报“已删除”。
  Future<bool> clearBinding();

  /// 当前注册状态（托盘菜单 / 设置页据此显示是否真的可用）。
  ShortcutRegistrationStatus get status;

  /// 当前**确实注册成功**的绑定（= 系统现在会响应的那个组合）；没有就是 null。
  ///
  /// 与 [configuredBinding] 必须分开看：
  /// - `activeBinding` 是「现在真的注册了什么」；
  /// - `configuredBinding` 是「偏好设置里存了什么」。
  /// 写偏好失败时两者会不一致，UI 必须分别显示，不能拿配置当“当前快捷键”。
  String? get activeBinding;

  /// 偏好设置里保存的绑定（可能还没生效，或和当前注册的不一致）。
  String? get configuredBinding;

  /// 最近一次注册/改绑失败的原因。
  Object? get lastError;

  DateTime? get lastRegisteredAt;

  /// 状态变化通知，供 UI 跟着刷新。
  ValueListenable<ShortcutRegistrationStatus> get registrationStatus;
}

/// 当前平台的快捷键实现。
ShortcutService get shortcutService => Platform.isMacOS
    ? MacosShortcutService.instance
    : GnomeShortcutService.instance;

/// 把绑定字符串（`<Alt>z`）转成给人看的文案，例如 macOS 上显示 `⌥+Z`。
///
/// 设置页和首次启动欢迎页共用，避免两处各写一套导致显示不一致。
String bindingDisplayLabel(String binding) {
  final isMacos = Platform.isMacOS;
  final modifiers = RegExp(r'<([^>]+)>')
      .allMatches(binding)
      .map((match) => _displayModifier(match.group(1)!, isMacos: isMacos))
      .where((value) => value.isNotEmpty)
      .toList();
  final key = binding.replaceAll(RegExp(r'<[^>]+>'), '');
  final displayKey = switch (key.toLowerCase()) {
    'return' => 'Enter',
    'back_space' => 'Backspace',
    'page_up' => 'PageUp',
    'page_down' => 'PageDown',
    'space' => 'Space',
    _ when key.length == 1 => key.toUpperCase(),
    _ => key,
  };
  return [...modifiers, displayKey].join('+');
}

String _displayModifier(String modifier, {required bool isMacos}) {
  return switch (modifier.toLowerCase()) {
    'control' => isMacos ? '⌃' : 'Ctrl',
    'alt' => isMacos ? '⌥' : 'Alt',
    'shift' => isMacos ? '⇧' : 'Shift',
    'super' || 'meta' => isMacos ? '⌘' : 'Super',
    _ => modifier,
  };
}
