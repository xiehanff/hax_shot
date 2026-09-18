import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hax_colors.dart';
import 'autostart_service.dart';
import 'shortcut_registration.dart';
import 'shortcut_service.dart';
import '../window/rounded_window.dart';

class ShortcutSettingsPage extends StatefulWidget {
  const ShortcutSettingsPage({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  State<ShortcutSettingsPage> createState() => _ShortcutSettingsPageState();
}

class _ShortcutSettingsPageState extends State<ShortcutSettingsPage> {
  final FocusNode _recordFocusNode = FocusNode(debugLabel: 'shortcut-recorder');

  String? _binding;
  bool _loading = true;
  bool _recording = false;
  bool _saving = false;
  bool _autoLaunch = false;
  bool _autoLaunchLoading = true;
  bool _autoLaunchSaving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBinding());
    unawaited(_loadAutoLaunch());
  }

  @override
  void dispose() {
    _recordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadBinding() async {
    try {
      final binding = await shortcutService.readBinding();
      if (!mounted) return;
      setState(() {
        _binding = binding;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '读取快捷键失败：$error';
      });
    }
  }

  Future<void> _loadAutoLaunch() async {
    try {
      final enabled = await autostartService.isEnabled();
      if (!mounted) return;
      setState(() {
        _autoLaunch = enabled;
        _autoLaunchLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _autoLaunchLoading = false;
        _message = '读取开机自启动状态失败：$error';
      });
    }
  }

  Future<void> _setAutoLaunch(bool enabled) async {
    if (_autoLaunchSaving) return;
    final previous = _autoLaunch;
    setState(() {
      _autoLaunch = enabled;
      _autoLaunchSaving = true;
      _message = enabled ? '正在启用开机自启动…' : '正在关闭开机自启动…';
    });

    try {
      await autostartService.setEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _autoLaunchSaving = false;
        _message = enabled ? '已启用开机自启动' : '已关闭开机自启动';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _autoLaunch = previous;
        _autoLaunchSaving = false;
        _message = '设置开机自启动失败：$error';
      });
    }
  }

  /// 状态卡的说明文案。
  ///
  /// 「配置里存着什么」和「系统现在响应什么」可能不是同一个组合（例如注册成功但
  /// 偏好没写成功），这时必须把真正生效的那个组合写出来，不能只显示配置值。
  String _statusSubtitle() {
    final active = shortcutService.activeBinding;
    final configured = shortcutService.configuredBinding;
    if (active != null && configured != null && active != configured) {
      return '系统当前响应 ${bindingDisplayLabel(active)}，'
          '配置里存的是 ${bindingDisplayLabel(configured)}';
    }
    if (active != null && configured == null) {
      // Windows 首次启动是“注册了默认值但没写偏好”（§24.3）：屏幕上真的响应的就是
      // active 那个组合，只写一句状态会让用户以为快捷键没生效。
      return '系统当前响应 ${bindingDisplayLabel(active)}（内置默认值，还没保存到配置）';
    }
    if (Platform.isMacOS) {
      return '当前注册状态（Carbon 是否接受了这个组合；'
          '失败时会带 OSStatus 记进诊断日志）';
    }
    if (Platform.isWindows) {
      // Windows 不写 OSStatus：它的原生错误码是 GetLastError()，文案不要拿
      // macOS 的说法套用户（§27）。
      return '当前注册状态（Windows 是否接受了这个组合；'
          '失败时会带 Win32 错误码记进诊断日志）';
    }
    return '当前注册状态';
  }

  String get _modifierHint {
    if (Platform.isMacOS) return '⌘、⌥、⌃ 或 ⇧';
    if (Platform.isWindows) return 'Alt、Ctrl、Win 或 Shift';
    return 'Alt、Ctrl 或 Super';
  }

  /// 自启动开关的说明文案（§36.2）。
  ///
  /// Windows 只能写 HKCU Run（§32.1）；系统“启动”页里的禁用开关存在
  /// `StartupApproved`，应用**不去改**它，所以只能提示用户去任务管理器恢复（§32.3）。
  String get _autostartSubtitle {
    if (Platform.isMacOS) return '登录后自动显示菜单栏图标';
    if (Platform.isWindows) {
      return '登录 Windows 后自动启动 HaxShot'
          '（若系统启动项被禁用，需到任务管理器的“启动”页恢复）';
    }
    return '登录 GNOME 后自动显示托盘图标';
  }

  String get _exampleShortcut => Platform.isMacOS ? '⌘+⇧+Z' : 'Alt+Shift+Z';

  void _startRecording() {
    setState(() {
      _recording = true;
      _message = '请按下新的快捷键（至少包含一个修饰键）';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordFocusNode.requestFocus();
    });
  }

  void _cancelRecording() {
    setState(() {
      _recording = false;
      _message = null;
    });
  }

  KeyEventResult _onShortcutKeyEvent(KeyEvent event) {
    if (!_recording || _saving) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelRecording();
      return KeyEventResult.handled;
    }

    final keyName = _bindingKeyName(event.logicalKey);
    if (keyName == null) {
      setState(() => _message = '这个按键不能作为快捷键主体，请再按一次');
      return KeyEventResult.handled;
    }

    final modifiers = _pressedModifiers();
    if (modifiers.isEmpty) {
      setState(() => _message = '快捷键至少需要一个修饰键，例如 $_modifierHint');
      return KeyEventResult.handled;
    }

    final binding = '${modifiers.map((item) => item.gsettings).join()}$keyName';
    final label =
        '${modifiers.map((item) => item.label).join('+')}+'
        '${_displayKeyName(event.logicalKey)}';
    unawaited(_saveBinding(binding, label));
    return KeyEventResult.handled;
  }

  /// 设置页显示的“当前快捷键”。
  ///
  /// 优先用偏好里的值；偏好里没有时回退到**系统现在真的注册着的**那个组合——
  /// Windows 首次启动只注册默认值、不写偏好（§24.3），只显示偏好会让用户看到
  /// “未设置”而实际按下 Alt+Shift+Z 能截图，也让他没法把默认值删掉。
  String? get _displayBinding => _binding ?? shortcutService.activeBinding;

  Future<void> _saveBinding(String binding, String label) async {
    setState(() {
      _saving = true;
      _message = '正在保存：$label';
    });

    // 改绑是事务：注册失败时服务会尝试回滚旧绑定，这里必须按结果区分文案，
    // 不能“写进偏好设置”就报“已设置”。
    final result = await shortcutService.saveBinding(binding);
    if (!mounted) return;
    switch (result) {
      case ShortcutActivationSuccess(:final persisted):
        setState(() {
          _binding = binding;
          _recording = false;
          _saving = false;
          // 注册成功不等于配置已保存：偏好写失败时本次可用，但重启会回到旧值。
          _message = persisted
              ? '已设置为 $label'
              : '已设置为 $label（本次已生效，但没能保存，重启后会恢复原快捷键）';
        });
      case ShortcutActivationFailure(
        :final error,
        :final restoredBinding,
        :final rollbackFailed,
      ):
        setState(() {
          _recording = false;
          _saving = false;
          if (rollbackFailed) {
            _message = '新快捷键注册失败，原快捷键也未能恢复，全局快捷键当前不可用：$error';
          } else if (restoredBinding != null) {
            _message =
                '新快捷键注册失败，已恢复原快捷键 '
                '${bindingDisplayLabel(restoredBinding)}：$error';
          } else {
            _message = '注册快捷键失败：$error';
          }
        });
    }
  }

  Future<void> _deleteBinding() async {
    if (_saving || _displayBinding == null) return;
    setState(() {
      _saving = true;
      _message = '正在删除快捷键…';
    });

    // clearBinding 返回 false 表示“没删掉”（注销失败或配置没写成功），
    // 这时不能显示“已删除”——系统里可能还留着这个组合。
    final cleared = await shortcutService.clearBinding();
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (cleared) {
        _binding = null;
        _message = '快捷键已删除';
      } else {
        _message =
            '删除快捷键失败：'
            '${shortcutService.lastError ?? '系统没有释放这个组合'}';
      }
    });
  }

  List<_ShortcutModifier> _pressedModifiers() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final modifiers = <_ShortcutModifier>[];
    if (pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight)) {
      modifiers.add(_ShortcutModifier.control);
    }
    if (pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight)) {
      modifiers.add(_ShortcutModifier.alt);
    }
    if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight)) {
      modifiers.add(_ShortcutModifier.shift);
    }
    if (pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight)) {
      modifiers.add(_ShortcutModifier.superKey);
    }
    return modifiers;
  }

  /// 产出三个平台共用的绑定键名，例如 `z`、`space`、`F5`。
  String? _bindingKeyName(LogicalKeyboardKey key) {
    if (_isModifier(key)) return null;

    final label = key.keyLabel.trim();
    if (label.isEmpty) return null;

    switch (key) {
      case LogicalKeyboardKey.space:
        return 'space';
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return 'Return';
      case LogicalKeyboardKey.tab:
        return 'Tab';
      case LogicalKeyboardKey.backspace:
        return 'BackSpace';
      case LogicalKeyboardKey.delete:
        return 'Delete';
      case LogicalKeyboardKey.insert:
        return 'Insert';
      case LogicalKeyboardKey.home:
        return 'Home';
      case LogicalKeyboardKey.end:
        return 'End';
      case LogicalKeyboardKey.pageUp:
        return 'Page_Up';
      case LogicalKeyboardKey.pageDown:
        return 'Page_Down';
      case LogicalKeyboardKey.arrowUp:
        return 'Up';
      case LogicalKeyboardKey.arrowDown:
        return 'Down';
      case LogicalKeyboardKey.arrowLeft:
        return 'Left';
      case LogicalKeyboardKey.arrowRight:
        return 'Right';
    }

    if (label.length == 1) return label.toLowerCase();
    if (RegExp(r'^F\d+$', caseSensitive: false).hasMatch(label)) {
      return label.toUpperCase();
    }
    return label.replaceAll(' ', '_');
  }

  bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  String _displayKeyName(LogicalKeyboardKey key) {
    final label = key.keyLabel.trim();
    if (label.length == 1) return label.toUpperCase();
    return label.isEmpty ? '按键' : label;
  }

  @override
  Widget build(BuildContext context) {
    // 只有按钮用主题的灰蓝（见 lib/hax_colors.dart）：覆盖 colorScheme.primary
    // 就够了，其余文字/底色保持主题中性色。
    final accented = haxAccentTheme(Theme.of(context));
    return Theme(
      data: accented,
      child: KeyboardListener(
        focusNode: _recordFocusNode,
        onKeyEvent: _onShortcutKeyEvent,
        child: RoundedWindow(
          child: Scaffold(
            appBar: AppBar(
              // 关闭按钮统一放右上角，和授权引导页/欢迎页保持一致。
              automaticallyImplyLeading: false,
              title: const Text('快捷键设置'),
              actions: [
                IconButton(
                  tooltip: '关闭',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.all(32),
                  shrinkWrap: true,
                  children: [
                    Text(
                      '截图快捷键',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '按下快捷键后，HaxShot 会启动全屏框选。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: ListTile(
                        onTap: _loading || _saving
                            ? null
                            : _recording
                            ? _cancelRecording
                            : _startRecording,
                        leading: const Icon(Icons.keyboard_alt_outlined),
                        title: Text(
                          _loading
                              ? '读取中…'
                              : _displayBinding == null
                              ? '未设置'
                              : bindingDisplayLabel(_displayBinding!),
                        ),
                        subtitle: const Text('当前快捷键'),
                        trailing: _displayBinding == null
                            ? null
                            : IconButton(
                                tooltip: '删除快捷键',
                                onPressed: _saving ? null : _deleteBinding,
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 「配置了什么」和「当前是否真的注册上了」必须分开显示：macOS 上
                    // 读取配置成功不等于 Carbon 真的记住了这个组合。
                    ValueListenableBuilder<ShortcutRegistrationStatus>(
                      valueListenable: shortcutService.registrationStatus,
                      builder: (context, status, _) {
                        final bool active =
                            status == ShortcutRegistrationStatus.active;
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              active
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline,
                            ),
                            title: Text(shortcutStatusLabel(status)),
                            subtitle: Text(_statusSubtitle()),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _loading || _saving
                          ? null
                          : _recording
                          ? _cancelRecording
                          : _startRecording,
                      icon: Icon(
                        _recording
                            ? Icons.stop_circle_outlined
                            : Icons.fiber_manual_record,
                      ),
                      label: Text(_recording ? '取消录制' : '录制新的快捷键'),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.power_settings_new),
                        title: const Text('开机自启动'),
                        subtitle: Text(_autostartSubtitle),
                        trailing: Switch(
                          value: _autoLaunch,
                          onChanged: _autoLaunchLoading || _autoLaunchSaving
                              ? null
                              : _setAutoLaunch,
                        ),
                      ),
                    ),
                    if (_recording) ...[
                      const SizedBox(height: 16),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            '请按下新的组合键，例如 $_exampleShortcut。\n按 Esc 可取消录制。',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ShortcutModifier {
  control('<Control>'),
  alt('<Alt>'),
  shift('<Shift>'),
  superKey('<Super>');

  const _ShortcutModifier(this.gsettings);

  final String gsettings;

  /// 录制时的即时标签（§27）：macOS 上是 Super 的键在 Windows 上叫 Win，
  /// Linux 上仍然叫 Super。
  String get label => switch (this) {
    _ShortcutModifier.control => 'Ctrl',
    _ShortcutModifier.alt => 'Alt',
    _ShortcutModifier.shift => 'Shift',
    _ShortcutModifier.superKey => Platform.isWindows ? 'Win' : 'Super',
  };
}
