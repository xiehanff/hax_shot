import 'package:flutter/foundation.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hotkey_binding.dart';
import 'shortcut_service.dart';

/// macOS 的全局快捷键用 [hotkeyManager]（底层是 soffes/HotKey 的 Carbon 实现）。
///
/// 选择成熟的第三方包而不是自己调 Carbon `RegisterEventHotKey`：托盘宿主是长驻
/// 进程，注册和注销都要处理生命周期，这件事没必要自己写。
final class MacosShortcutService implements ShortcutService {
  MacosShortcutService();

  static final instance = MacosShortcutService();

  static const bindingKey = 'hax_shot.capture_shortcut';

  /// 首次启动时使用的默认快捷键。
  ///
  /// 菜单栏图标可能被 Bartender 这类菜单栏管理工具收进隐藏区，所以截图工具必须有
  /// 一个不依赖图标的入口；用户可以在设置页随时改掉它。
  static const defaultBinding = '<Super><Shift>z';

  /// 1.4.1 及更早版本自动写入的默认值；启动时迁移到新的 ⌘⇧Z。
  static const _legacyDefaultBinding = '<Alt>z';

  HotKey? _registered;

  @override
  Future<void> activate({required void Function() onTriggered}) async {
    // 读配置、注册失败都不能冒泡出去：托盘菜单的创建排在后面，一旦中断用户就没有
    // 任何入口了（托盘菜单里才有“立即截屏”）。
    try {
      var binding = await readBinding();
      if (binding == null || binding == _legacyDefaultBinding) {
        final migrated = binding == _legacyDefaultBinding;
        binding = defaultBinding;
        await _writeBinding(binding);
        debugPrint(
          migrated ? '已把旧默认快捷键迁移为：$binding' : '首次启动，使用默认全局快捷键：$binding',
        );
      }
      await _register(binding, onTriggered);
    } on Object catch (error) {
      debugPrint('注册全局快捷键失败：$error');
    }
  }

  @override
  Future<String?> readBinding() async {
    final preferences = await SharedPreferences.getInstance();
    final binding = preferences.getString(bindingKey);
    return (binding == null || binding.isEmpty) ? null : binding;
  }

  @override
  Future<void> saveBinding(String binding) async {
    final onTriggered = _onTriggered;
    if (onTriggered == null) {
      throw StateError('快捷键服务还没有激活');
    }
    await _register(binding, onTriggered);
    await _writeBinding(binding);
  }

  @override
  Future<void> clearBinding() async {
    await _unregister();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(bindingKey);
  }

  void Function()? _onTriggered;

  Future<void> _register(String binding, void Function() onTriggered) async {
    final hotKey = hotKeyFromBinding(binding);
    if (hotKey == null) {
      throw FormatException('macOS 不支持这个按键：$binding');
    }

    // 先注册新的再注销旧的：新快捷键被别的应用占用时，旧快捷键仍然可用。
    final previous = _registered;
    await hotKeyManager.register(hotKey, keyDownHandler: (_) => onTriggered());
    _registered = hotKey;
    _onTriggered = onTriggered;
    if (previous != null && previous.identifier != hotKey.identifier) {
      await hotKeyManager.unregister(previous);
    }
  }

  Future<void> _unregister() async {
    final current = _registered;
    if (current == null) return;
    _registered = null;
    await hotKeyManager.unregister(current);
  }

  Future<void> _writeBinding(String binding) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(bindingKey, binding);
  }
}
