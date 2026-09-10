import 'dart:io';

import 'gnome_shortcut_service.dart';
import 'macos_shortcut_service.dart';

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
  Future<void> activate({required void Function() onTriggered});

  Future<String?> readBinding();

  Future<void> saveBinding(String binding);

  Future<void> clearBinding();
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
