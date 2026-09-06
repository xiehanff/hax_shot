import 'dart:io';

/// Manages the user's XDG autostart entry for the tray host.
///
/// This intentionally writes to the user profile instead of installing a
/// system-wide entry. RPM installation can therefore be shared by multiple
/// users without changing their personal login behavior.
final class AutostartService {
  AutostartService({this._configHome, this._executablePath});

  static final instance = AutostartService();

  static const desktopFileName = 'com.github.xiehanff.hax_shot.desktop';

  final String? _configHome;
  final String? _executablePath;

  String get _autostartPath {
    final configHome =
        _configHome ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        '${Platform.environment['HOME'] ?? Directory.current.path}/.config';
    return '$configHome/autostart/$desktopFileName';
  }

  Future<bool> isEnabled() async {
    final file = File(_autostartPath);
    if (!await file.exists()) return false;
    final content = await file.readAsString();
    return !RegExp(r'^Hidden=true\s*$', multiLine: true).hasMatch(content) &&
        !RegExp(
          r'^X-GNOME-Autostart-enabled=false\s*$',
          multiLine: true,
        ).hasMatch(content);
  }

  Future<void> setEnabled(bool enabled) async {
    final file = File(_autostartPath);
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(_desktopEntry());
  }

  String _desktopEntry() {
    final executable = _executablePath ?? Platform.resolvedExecutable;
    final escaped = executable.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final command = executable.contains(RegExp(r'\s')) ? '"$escaped"' : escaped;
    return '''[Desktop Entry]
Type=Application
Name=Hax Shot
Comment=Hax Shot tray host
Exec=$command
Icon=com.github.xiehanff.hax_shot
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
''';
  }
}
