import 'dart:io';

import 'package:flutter/foundation.dart';

import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';
import 'shortcut_registration.dart';
import 'shortcut_service.dart';

/// GNOME custom shortcut location used by HaxShot.
///
/// 快捷键由 GNOME 自己持有（gsettings 里保存的是 `hax_shot --capture`），宿主
/// 不需要向系统注册任何东西，所以这里没有 macOS 那样的注册/回滚事务：
/// `saveBinding` 就是一次 gsettings 写入，写成功即“已生效”。
final class GnomeShortcutService implements ShortcutService {
  GnomeShortcutService({
    String? executablePath,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
    DiagnosticLogService? log,
  }) : _executablePath = executablePath ?? Platform.resolvedExecutable,
       _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments)),
       _log = log ?? DiagnosticLogService.instance;

  static final instance = GnomeShortcutService();

  static const mediaKeysSchema = 'org.gnome.settings-daemon.plugins.media-keys';
  static const keyPath =
      '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hax-shot/';
  static const bindingSchema =
      'org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$keyPath';
  static const name = 'HaxShot Capture';

  final String _executablePath;
  final Future<ProcessResult> Function(String, List<String>) _processRunner;
  final DiagnosticLogService _log;

  final ValueNotifier<ShortcutRegistrationStatus> _status =
      ValueNotifier<ShortcutRegistrationStatus>(
        ShortcutRegistrationStatus.inactive,
      );

  String? _activeBinding;
  Object? _lastError;
  DateTime? _lastRegisteredAt;

  @override
  ShortcutRegistrationStatus get status => _status.value;

  @override
  String? get activeBinding => _activeBinding;

  /// GNOME 没有独立的“已注册”层：gsettings 里的值就是系统实际执行的值。
  @override
  String? get configuredBinding => _activeBinding;

  @override
  Object? get lastError => _lastError;

  @override
  DateTime? get lastRegisteredAt => _lastRegisteredAt;

  @override
  ValueListenable<ShortcutRegistrationStatus> get registrationStatus => _status;

  /// GNOME 自己持有快捷键，宿主只需要确认 gsettings 里有没有配好。
  @override
  Future<ShortcutActivationResult> activate({
    required void Function() onTriggered,
  }) async {
    if (Platform.isLinux) {
      // GNOME 会直接启动 `hax_shot --capture`，宿主的回调永远不会被用到。
      _log.log(
        'shortcut_activate_skipped',
        message: 'GNOME 由 gsettings 直接启动捕获进程，宿主不注册全局快捷键',
      );
    }
    try {
      final binding = await readBinding();
      if (binding == null) {
        _activeBinding = null;
        _setStatus(ShortcutRegistrationStatus.inactive);
        return const ShortcutActivationFailure(
          binding: '',
          error: '还没有配置 GNOME 自定义快捷键',
        );
      }
      _activeBinding = binding;
      _lastError = null;
      _lastRegisteredAt = DateTime.now();
      _setStatus(ShortcutRegistrationStatus.active);
      return ShortcutActivationSuccess(binding: binding);
    } on Object catch (error) {
      _lastError = error;
      _setStatus(ShortcutRegistrationStatus.failed);
      return ShortcutActivationFailure(
        binding: _activeBinding ?? '',
        error: error,
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
      );
    }
  }

  @override
  Future<ShortcutActivationResult> reactivate() => activate(onTriggered: () {});

  @override
  Future<String?> readBinding() async {
    final result = await _runGsettings(['get', bindingSchema, 'binding']);
    final binding = _parseGvariantString(result.stdout.toString());
    return binding.isEmpty ? null : binding;
  }

  @override
  Future<ShortcutActivationResult> saveBinding(String binding) async {
    try {
      await _ensureCustomKeybindingIsActive();
      await _setGsettings(bindingSchema, 'name', name);
      await _setGsettings(bindingSchema, 'command', _captureCommand);
      await _setGsettings(bindingSchema, 'binding', binding);
    } on Object catch (error) {
      _lastError = error;
      _setStatus(ShortcutRegistrationStatus.failed);
      return ShortcutActivationFailure(
        binding: binding,
        error: error,
        errorCode: DiagnosticErrorCode.shortcutRegisterFailed,
        restoredBinding: _activeBinding,
      );
    }
    _activeBinding = binding;
    _lastError = null;
    _lastRegisteredAt = DateTime.now();
    _setStatus(ShortcutRegistrationStatus.active);
    return ShortcutActivationSuccess(binding: binding);
  }

  /// 返回 false 表示 gsettings 没写成功，快捷键可能还在生效。
  @override
  Future<bool> clearBinding() async {
    try {
      await _setGsettings(bindingSchema, 'binding', '');
    } on Object catch (error) {
      _lastError = error;
      _setStatus(ShortcutRegistrationStatus.failed);
      return false;
    }
    _activeBinding = null;
    _setStatus(ShortcutRegistrationStatus.inactive);
    return true;
  }

  void _setStatus(ShortcutRegistrationStatus value) {
    if (_status.value == value) return;
    _status.value = value;
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
