import 'dart:io';

import 'shortcut_service.dart';

/// GNOME custom shortcut location used by Hax Shot.
final class GnomeShortcutService implements ShortcutService {
  GnomeShortcutService({
    String? executablePath,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
  }) : _executablePath = executablePath ?? Platform.resolvedExecutable,
       _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments));

  static final instance = GnomeShortcutService();

  static const mediaKeysSchema = 'org.gnome.settings-daemon.plugins.media-keys';
  static const keyPath =
      '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hax-shot/';
  static const bindingSchema =
      'org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$keyPath';
  static const name = 'Hax Shot Capture';

  final String _executablePath;
  final Future<ProcessResult> Function(String, List<String>) _processRunner;

  /// GNOME 自己持有快捷键（gsettings 里保存的是 `hax_shot --capture`），
  /// 按一下由系统直接启动子进程，托盘宿主不需要注册什么。
  @override
  Future<void> activate({required void Function() onTriggered}) async {}

  @override
  Future<String?> readBinding() async {
    final result = await _runGsettings(['get', bindingSchema, 'binding']);
    final binding = _parseGvariantString(result.stdout.toString());
    return binding.isEmpty ? null : binding;
  }

  @override
  Future<void> saveBinding(String binding) async {
    await _ensureCustomKeybindingIsActive();
    await _setGsettings(bindingSchema, 'name', name);
    await _setGsettings(bindingSchema, 'command', _captureCommand);
    await _setGsettings(bindingSchema, 'binding', binding);
  }

  @override
  Future<void> clearBinding() async {
    await _setGsettings(bindingSchema, 'binding', '');
  }

  Future<void> _ensureCustomKeybindingIsActive() async {
    final result = await _runGsettings([
      'get',
      mediaKeysSchema,
      'custom-keybindings',
    ]);
    final current = _parseGvariantArray(result.stdout.toString());
    if (current.contains(keyPath)) return;

    current.add(keyPath);
    final value = '[${current.map(_quoteGvariantString).join(', ')}]';
    await _runGsettings(['set', mediaKeysSchema, 'custom-keybindings', value]);
  }

  Future<ProcessResult> _runGsettings(List<String> arguments) async {
    final result = await _processRunner('gsettings', arguments);
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
    final escaped = _executablePath.replaceAll('"', '\\"');
    return _executablePath.contains(' ')
        ? '"$escaped" --capture'
        : '$_executablePath --capture';
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
}
