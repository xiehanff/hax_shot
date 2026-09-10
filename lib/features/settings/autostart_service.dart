import 'dart:io';

/// 开机自启动开关的平台接口。
abstract interface class AutostartService {
  Future<bool> isEnabled();

  Future<void> setEnabled(bool enabled);
}

/// 当前平台的开机自启动实现。
AutostartService get autostartService => Platform.isMacOS
    ? MacosAutostartService.instance
    : XdgAutostartService.instance;

/// Manages the user's XDG autostart entry for the tray host.
///
/// This intentionally writes to the user profile instead of installing a
/// system-wide entry. RPM installation can therefore be shared by multiple
/// users without changing their personal login behavior.
final class XdgAutostartService implements AutostartService {
  XdgAutostartService({this._configHome, this._executablePath});

  static final instance = XdgAutostartService();

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

  @override
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

  @override
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

/// macOS 使用用户级 LaunchAgent 实现开机自启动。
///
/// 只写 plist 文件，不调用 `launchctl bootstrap`：LaunchAgent 会在下次登录时被
/// launchd 自动加载，而立刻 bootstrap 会在用户已经运行托盘宿主时再开一个实例。
final class MacosAutostartService implements AutostartService {
  MacosAutostartService({this._homeDirectory, this._executablePath});

  static final instance = MacosAutostartService();

  /// 与 macOS Runner 的 PRODUCT_BUNDLE_IDENTIFIER 保持一致。
  static const label = 'com.github.xiehanff.haxShot';

  final String? _homeDirectory;
  final String? _executablePath;

  String get _plistPath {
    final home = _homeDirectory ?? Platform.environment['HOME'];
    if (home == null) {
      throw StateError('无法确定用户主目录，不能写入 LaunchAgent');
    }
    return '$home/Library/LaunchAgents/$label.plist';
  }

  @override
  Future<bool> isEnabled() => File(_plistPath).exists();

  @override
  Future<void> setEnabled(bool enabled) async {
    final file = File(_plistPath);
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(_launchAgent());
  }

  String _launchAgent() {
    final executable = _executablePath ?? Platform.resolvedExecutable;
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_escapeXml(executable)}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
''';
  }

  String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
