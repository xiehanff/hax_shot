import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The GNOME custom shortcut location installed by
/// scripts/install-gnome-shortcut.sh.
final class ShortcutSettings {
  static const mediaKeysSchema = 'org.gnome.settings-daemon.plugins.media-keys';
  static const keyPath =
      '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/easy-shot/';
  static const bindingSchema =
      'org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$keyPath';
  static const name = 'Easy Shot Capture';

  const ShortcutSettings._();
}

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
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBinding());
  }

  @override
  void dispose() {
    _recordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadBinding() async {
    try {
      final result = await _runGsettings([
        'get',
        ShortcutSettings.bindingSchema,
        'binding',
      ]);
      final binding = _parseGvariantString(result.stdout.toString());
      if (!mounted) return;
      setState(() {
        _binding = binding.isEmpty ? null : binding;
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

  Future<void> _startRecording() async {
    setState(() {
      _recording = true;
      _message = '请按下新的快捷键（至少包含一个修饰键）';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordFocusNode.requestFocus();
    });
  }

  void _cancelRecording() {
    if (!mounted) return;
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

    final keyName = _gsettingsKeyName(event.logicalKey);
    if (keyName == null) {
      setState(() => _message = '这个按键不能作为快捷键主体，请再按一次');
      return KeyEventResult.handled;
    }

    final modifiers = _pressedModifiers();
    if (modifiers.isEmpty) {
      setState(() => _message = '快捷键至少需要一个修饰键，例如 Alt、Ctrl 或 Super');
      return KeyEventResult.handled;
    }

    final binding = '${modifiers.map((item) => item.gsettings).join()}$keyName';
    final label =
        '${modifiers.map((item) => item.label).join('+')}+'
        '${_displayKeyName(event.logicalKey)}';
    unawaited(_saveBinding(binding, label));
    return KeyEventResult.handled;
  }

  Future<void> _saveBinding(String binding, String label) async {
    setState(() {
      _saving = true;
      _message = '正在保存：$label';
    });

    try {
      await _ensureCustomKeybindingIsActive();
      await _setGsettings(
        ShortcutSettings.bindingSchema,
        'name',
        ShortcutSettings.name,
      );
      await _setGsettings(
        ShortcutSettings.bindingSchema,
        'command',
        _captureCommand,
      );
      await _setGsettings(ShortcutSettings.bindingSchema, 'binding', binding);
      if (!mounted) return;
      setState(() {
        _binding = binding;
        _recording = false;
        _saving = false;
        _message = '已设置为 $label';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = '保存快捷键失败：$error';
      });
    }
  }

  Future<void> _deleteBinding() async {
    if (_saving || _binding == null) return;
    setState(() {
      _saving = true;
      _message = '正在删除快捷键…';
    });

    try {
      // Keep the relocatable GSettings entry in the collection, but clear its
      // binding. This makes recording a new key later work without requiring
      // the installer script to run again.
      await _setGsettings(ShortcutSettings.bindingSchema, 'binding', '');
      if (!mounted) return;
      setState(() {
        _binding = null;
        _saving = false;
        _message = '快捷键已删除';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = '删除快捷键失败：$error';
      });
    }
  }

  Future<void> _ensureCustomKeybindingIsActive() async {
    final result = await _runGsettings([
      'get',
      ShortcutSettings.mediaKeysSchema,
      'custom-keybindings',
    ]);
    final current = _parseGvariantArray(result.stdout.toString());
    if (current.contains(ShortcutSettings.keyPath)) return;

    current.add(ShortcutSettings.keyPath);
    final value = '[${current.map(_quoteGvariantString).join(', ')}]';
    await _runGsettings([
      'set',
      ShortcutSettings.mediaKeysSchema,
      'custom-keybindings',
      value,
    ]);
  }

  Future<ProcessResult> _runGsettings(List<String> arguments) async {
    final result = await Process.run('gsettings', arguments);
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw StateError(
        error.isEmpty ? 'gsettings exited ${result.exitCode}' : error,
      );
    }
    return result;
  }

  Future<void> _setGsettings(String schema, String key, String value) async {
    await _runGsettings(['set', schema, key, value]);
  }

  String get _captureCommand {
    final executable = Platform.resolvedExecutable;
    // Process.run does not invoke a shell, but GNOME later parses this value
    // as a command line. Quote paths containing spaces for that later parse.
    final escaped = executable.replaceAll('"', '\\"');
    final command = executable.contains(' ')
        ? '"$escaped" --capture'
        : '$executable --capture';
    return command;
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

  String? _gsettingsKeyName(LogicalKeyboardKey key) {
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

  String _parseGvariantString(String output) {
    var value = output.trim();
    if (value.startsWith('@s ')) value = value.substring(3).trim();
    if (value == "''" || value == '""') return '';
    if (value.length >= 2 &&
        ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"')))) {
      value = value.substring(1, value.length - 1);
    }
    return value.replaceAll(r"\'", "'").replaceAll(r'\"', '"');
  }

  List<String> _parseGvariantArray(String output) {
    return RegExp(
      r'''['"]([^'"]*)['"]''',
    ).allMatches(output).map((match) => match.group(1)!).toList();
  }

  String _quoteGvariantString(String value) {
    return "'${value.replaceAll("'", r"\'")}'";
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _recordFocusNode,
      onKeyEvent: _onShortcutKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
          title: const Text('快捷键设置'),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(32),
              shrinkWrap: true,
              children: [
                Text('截图快捷键', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  '按下快捷键后，Easy Shot 会启动全屏框选。',
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
                          : _binding == null
                          ? '未设置'
                          : _displayBinding(_binding!),
                    ),
                    subtitle: const Text('当前快捷键'),
                    trailing: _binding == null
                        ? null
                        : IconButton(
                            tooltip: '删除快捷键',
                            onPressed: _saving ? null : _deleteBinding,
                            icon: const Icon(Icons.close),
                          ),
                  ),
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
                if (_recording) ...[
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '请按下新的组合键，例如 Alt+Z。\n按 Esc 可取消录制。',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
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
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _displayBinding(String binding) {
    final modifiers = RegExp(r'<([^>]+)>')
        .allMatches(binding)
        .map((match) => _displayModifier(match.group(1)!))
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

  String _displayModifier(String modifier) {
    return switch (modifier.toLowerCase()) {
      'control' => 'Ctrl',
      'alt' => 'Alt',
      'shift' => 'Shift',
      'super' || 'meta' => 'Super',
      _ => modifier,
    };
  }
}

enum _ShortcutModifier {
  control('<Control>', 'Ctrl'),
  alt('<Alt>', 'Alt'),
  shift('<Shift>', 'Shift'),
  superKey('<Super>', 'Super');

  const _ShortcutModifier(this.gsettings, this.label);

  final String gsettings;
  final String label;
}
