import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';

/// 开机自启动开关的平台接口。
abstract interface class AutostartService {
  Future<bool> isEnabled();

  Future<void> setEnabled(bool enabled);
}

/// 当前平台的开机自启动实现。
///
/// 显式三平台选择（§26/§32）：禁止“else = Linux”，否则 Windows 会写 XDG 桌面项。
AutostartService get autostartService {
  if (Platform.isMacOS) return MacosAutostartService.instance;
  if (Platform.isWindows) return WindowsAutostartService.instance;
  if (Platform.isLinux) return XdgAutostartService.instance;
  throw UnsupportedError('不支持的桌面平台：${Platform.operatingSystem}');
}

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
Name=HaxShot
Comment=HaxShot tray host
Exec=$command
Icon=com.github.xiehanff.hax_shot
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
''';
  }
}

/// Windows 用当前用户 HKCU Run 值实现开机自启动（§32）。
///
/// - 写 `Software\Microsoft\Windows\CurrentVersion\Run` 下名为 `HaxShot` 的值，
///   数据是**带引号**的当前 exe 绝对路径（可能含空格/中文）；
/// - 用户级、不需要管理员，不用 Startup 文件夹与 `.lnk`；
/// - `isEnabled()` 不是“存在同名值就算开”：必须与当前 exe 路径一致（§32.2），
///   否则 ZIP 换目录后会谎报“已开启”而实际上启到不存在的旧路径；
/// - 写失败 / 回读不一致一律抛错，不报成功；关掉时只删自己那个值。
final class WindowsAutostartService implements AutostartService {
  WindowsAutostartService({String? executablePath})
    : _executablePath = executablePath ?? Platform.resolvedExecutable;

  static final instance = WindowsAutostartService();

  /// 注册表值名：只认自己这一个名字（不碰 Run 下其它项）。
  static const String valueName = 'HaxShot';

  /// HKCU 下的 Run 键路径。
  static const String runKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  final String _executablePath;

  /// 真正写进注册表的数据：带引号的 exe 绝对路径。
  String get _quotedExecutablePath => '"$_executablePath"';

  @override
  Future<bool> isEnabled() async {
    final String? value = _readValue();
    if (value == null) return false;
    if (_pointsAtCurrentExecutable(value)) return true;

    // 值在、但不是当前 exe（例如 ZIP 换了目录）：按“没启用”处理，
    // 但日志里要说清楚，否则用户只会看到开关自己关掉而不知道为什么。
    DiagnosticLogService.instance.log(
      DiagnosticEvent.autostartStaleValue,
      level: LogLevel.warning,
      message: 'HKCU Run 的 $valueName 指向 $value，不是当前 exe $_executablePath',
      extra: <String, Object?>{
        'registry_value': value,
        'executable': _executablePath,
      },
    );
    return false;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      _writeValue(_quotedExecutablePath);

      // 写成功不代表写对了：回读一次，不是当前 exe 就当作失败报出去（§32.2）。
      final String? readBack = _readValue();
      if (readBack == null || !_pointsAtCurrentExecutable(readBack)) {
        const String message = 'HKCU Run 写入后回读不一致';
        DiagnosticLogService.instance.log(
          DiagnosticEvent.autostartWriteFailed,
          level: LogLevel.error,
          errorCode: DiagnosticErrorCode.autostartFailed,
          message: '$message：读回 $readBack，期望 $_quotedExecutablePath',
        );
        throw WindowsAutostartException('$message（读回 $readBack）');
      }

      DiagnosticLogService.instance.log(
        DiagnosticEvent.autostartWriteSuccess,
        message: 'HKCU Run 已写入 $valueName=$readBack',
      );
      return;
    }

    _deleteValue();
    DiagnosticLogService.instance.log(
      DiagnosticEvent.autostartRemoveSuccess,
      message: 'HKCU Run 已删除 $valueName',
    );
  }

  /// 值数据是否就是当前 exe。
  ///
  /// 比较时去掉引号、忽略大小写：Windows 路径大小写不敏感，历史上/手工写进去的
  /// 项也不一定带引号。“值与当前 exe 路径一致”这个语义不变。
  bool _pointsAtCurrentExecutable(String value) =>
      _normalize(value) == _normalize(_executablePath);

  static String _normalize(String value) =>
      value.replaceAll('"', '').toLowerCase();

  /// 读 Run 下的 `HaxShot` 值；值或键不存在返回 null，其它错误抛异常。
  String? _readValue() {
    final api = _RegistryApi.instance;
    final key = api.openKey(
      _RegistryApi.hkeyCurrentUser,
      runKeyPath,
      _RegistryApi.keyQueryValue,
    );
    if (key == null) {
      // 键不存在（极罕见：Run 键被删过）= 没启用，不是错误。
      return null;
    }

    try {
      return api.queryString(key, valueName);
    } on WindowsAutostartException catch (error) {
      DiagnosticLogService.instance.log(
        DiagnosticEvent.autostartReadFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.autostartFailed,
        message: '读取 HKCU Run 的 $valueName 失败：${error.message}',
        extra: <String, Object?>{'lstatus': error.status},
      );
      rethrow;
    } finally {
      api.closeKey(key);
    }
  }

  /// 写 Run 下的 `HaxShot` 值；任何非 ERROR_SUCCESS 都抛异常。
  void _writeValue(String value) {
    final api = _RegistryApi.instance;
    final key = api.createKey(
      _RegistryApi.hkeyCurrentUser,
      runKeyPath,
      _RegistryApi.keySetValue,
    );
    try {
      api.setString(key, valueName, value);
    } on WindowsAutostartException catch (error) {
      DiagnosticLogService.instance.log(
        DiagnosticEvent.autostartWriteFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.autostartFailed,
        message: '写入 HKCU Run 的 $valueName 失败：${error.message}',
        extra: <String, Object?>{'lstatus': error.status},
      );
      rethrow;
    } finally {
      api.closeKey(key);
    }
  }

  /// 删 Run 下的 `HaxShot` 值；值本来就不存在也算成功（幂等）。
  void _deleteValue() {
    final api = _RegistryApi.instance;
    final key = api.openKey(
      _RegistryApi.hkeyCurrentUser,
      runKeyPath,
      _RegistryApi.keySetValue,
    );
    if (key == null) return;

    try {
      api.deleteValue(key, valueName);
    } on WindowsAutostartException catch (error) {
      DiagnosticLogService.instance.log(
        DiagnosticEvent.autostartWriteFailed,
        level: LogLevel.error,
        errorCode: DiagnosticErrorCode.autostartFailed,
        message: '删除 HKCU Run 的 $valueName 失败：${error.message}',
        extra: <String, Object?>{'lstatus': error.status},
      );
      rethrow;
    } finally {
      api.closeKey(key);
    }
  }
}

/// Windows 注册表操作失败。
///
/// [status] 是注册表 API 直接返回的 LSTATUS：不再去读陈旧的 `GetLastError`（§9.7）。
final class WindowsAutostartException implements Exception {
  const WindowsAutostartException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// advapi32.dll 的最小注册表封装（只服务开机自启动）。
///
/// 直接用 FFI 而不是走 `reg.exe`：注册表 API 自己就返回 LSTATUS，
/// 失败原因（拒绝访问 / 键不存在）能原样写进日志；子进程退出码要另做映射，
/// 反而多一层不可靠的信息。
final class _RegistryApi {
  _RegistryApi._(DynamicLibrary library)
    : _regCreateKeyExW = library
          .lookupFunction<_RegCreateKeyExWNative, _RegCreateKeyExWDart>(
            'RegCreateKeyExW',
          ),
      _regOpenKeyExW = library
          .lookupFunction<_RegOpenKeyExWNative, _RegOpenKeyExWDart>(
            'RegOpenKeyExW',
          ),
      _regSetValueExW = library
          .lookupFunction<_RegSetValueExWNative, _RegSetValueExWDart>(
            'RegSetValueExW',
          ),
      _regQueryValueExW = library
          .lookupFunction<_RegQueryValueExWNative, _RegQueryValueExWDart>(
            'RegQueryValueExW',
          ),
      _regDeleteValueW = library
          .lookupFunction<_RegDeleteValueWNative, _RegDeleteValueWDart>(
            'RegDeleteValueW',
          ),
      _regCloseKey = library
          .lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>('RegCloseKey');

  /// 只有真的走 Windows 分支时才会加载 advapi32（macOS/Linux 进不来）。
  static _RegistryApi? _instance;

  static _RegistryApi get instance =>
      _instance ??= _RegistryApi._(DynamicLibrary.open('advapi32.dll'));

  /// `HKEY_CURRENT_USER`：winreg.h 里是 `((HKEY)(ULONG_PTR)((LONG)0x80000001))`，
  /// 64 位进程里必须按**符号扩展**后的值传（0xFFFFFFFF80000001 = -2147483647），
  /// 否则系统不认这个预定义句柄。
  static const int hkeyCurrentUser = 0xFFFFFFFF80000001;

  /// `KEY_QUERY_VALUE` / `KEY_SET_VALUE`：够读/写 `HaxShot` 一个值就行。
  static const int keyQueryValue = 0x0001;
  static const int keySetValue = 0x0002;

  static const int errorSuccess = 0;
  static const int errorFileNotFound = 2;
  static const int errorAccessDenied = 5;
  static const int errorMoreData = 234;

  /// 值的类型：`REG_SZ`。
  static const int regSz = 1;

  /// `REG_SZ` 的读取上限：64 KiB（32767 个 UTF-16 code unit + 终止 NUL）。
  ///
  /// 足够装下 Windows 允许的最长路径，但能挡住损坏 / 恶意值里的巨大 `size`：
  /// 不设上限时 `calloc(bytes)` 会直接按注册表声明的字节数分配（评审 4）。
  static const int _maxRegStringBytes = 64 * 1024;

  final _RegCreateKeyExWDart _regCreateKeyExW;
  final _RegOpenKeyExWDart _regOpenKeyExW;
  final _RegSetValueExWDart _regSetValueExW;
  final _RegQueryValueExWDart _regQueryValueExW;
  final _RegDeleteValueWDart _regDeleteValueW;
  final _RegCloseKeyDart _regCloseKey;

  /// 打开已存在的键；键不存在返回 null，其它 LSTATUS 抛异常。
  Pointer<Void>? openKey(int root, String subKey, int access) {
    final Pointer<Utf16> path = subKey.toNativeUtf16();
    final Pointer<IntPtr> handle = calloc<IntPtr>();
    try {
      final int status = _regOpenKeyExW(root, path, 0, access, handle);
      if (status == errorSuccess) {
        return Pointer<Void>.fromAddress(handle.value);
      }
      if (status == errorFileNotFound) {
        return null;
      }
      throw WindowsAutostartException(
        'RegOpenKeyExW(HKCU\\$subKey) 失败：${_describeLstatus(status)}',
        status: status,
      );
    } finally {
      calloc.free(handle);
      malloc.free(path);
    }
  }

  /// 打开/创建键（`Run` 键正常情况下已存在，但不存在时也不要报错）。
  Pointer<Void> createKey(int root, String subKey, int access) {
    final Pointer<Utf16> path = subKey.toNativeUtf16();
    final Pointer<Utf16> className = ''.toNativeUtf16();
    final Pointer<IntPtr> handle = calloc<IntPtr>();
    final Pointer<Uint32> disposition = calloc<Uint32>();
    try {
      final int status = _regCreateKeyExW(
        root,
        path,
        0,
        className,
        0,
        access | keyQueryValue,
        nullptr,
        handle,
        disposition,
      );
      if (status != errorSuccess) {
        throw WindowsAutostartException(
          'RegCreateKeyExW(HKCU\\$subKey) 失败：${_describeLstatus(status)}',
          status: status,
        );
      }
      return Pointer<Void>.fromAddress(handle.value);
    } finally {
      calloc.free(disposition);
      calloc.free(handle);
      malloc.free(className);
      malloc.free(path);
    }
  }

  /// 写一个 `REG_SZ` 值（UTF-16 + 结尾 NUL）。
  void setString(Pointer<Void> key, String name, String value) {
    final Pointer<Utf16> wideName = name.toNativeUtf16();
    final Pointer<Utf16> wideValue = value.toNativeUtf16();
    // REG_SZ 的字节数包含结尾的 NUL。
    final int byteLength = (value.length + 1) * 2;
    try {
      final int status = _regSetValueExW(
        key.address,
        wideName,
        0,
        regSz,
        wideValue.cast<Uint8>(),
        byteLength,
      );
      if (status != errorSuccess) {
        throw WindowsAutostartException(
          'RegSetValueExW($name) 失败：${_describeLstatus(status)}',
          status: status,
        );
      }
    } finally {
      malloc.free(wideValue);
      malloc.free(wideName);
    }
  }

  /// 读一个 `REG_SZ` 值；值不存在返回 null。
  ///
  /// 注册表返回的 `REG_SZ` **不保证**带结尾 NUL，也不保证长度可信（用户、策略软件
  /// 或损坏的值都可能写出无终止 NUL 的字节）。所以这里：
  ///
  /// - 拒绝奇数字节数与超过 [_maxRegStringBytes] 的值（不是合法的 `REG_SZ`）；
  /// - 多分配一个 UTF-16 code unit，保证缓冲区末尾一定是 NUL；
  /// - 按实际字节数**有界**读取，手工扫描终止 NUL 后才转换——绝不调用无界的
  ///   `toDartString()`（它会越过分配区一直扫到内存里的第一个 NUL）。
  String? queryString(Pointer<Void> key, String name) {
    final Pointer<Utf16> wideName = name.toNativeUtf16();
    final Pointer<Uint32> type = calloc<Uint32>();
    final Pointer<Uint32> size = calloc<Uint32>();
    try {
      // 第一次只问长度与类型（lpData = NULL）。
      int status = _regQueryValueExW(
        key.address,
        wideName,
        nullptr,
        type,
        nullptr,
        size,
      );
      if (status == errorFileNotFound) return null;
      if (status != errorSuccess) {
        throw WindowsAutostartException(
          'RegQueryValueExW($name) 取长度失败：${_describeLstatus(status)}',
          status: status,
        );
      }
      if (type.value != regSz) {
        throw WindowsAutostartException(
          'RegQueryValueExW($name) 的类型是 ${type.value}，不是 REG_SZ',
        );
      }

      final int bytes = size.value;
      if (bytes == 0) return '';
      if (bytes.isOdd) {
        throw WindowsAutostartException(
          'RegQueryValueExW($name) 返回奇数字节数 $bytes，不是合法的 REG_SZ，拒绝读取',
        );
      }
      if (bytes > _maxRegStringBytes) {
        throw WindowsAutostartException(
          'RegQueryValueExW($name) 的值有 $bytes 字节，超过 $_maxRegStringBytes 字节上限，拒绝读取',
        );
      }

      // 多一个 UTF-16 code unit：即使数据本身没有终止 NUL，分配区末尾也一定是 0。
      final Pointer<Uint8> buffer = calloc<Uint8>(bytes + 2);
      try {
        status = _regQueryValueExW(
          key.address,
          wideName,
          nullptr,
          type,
          buffer,
          size,
        );
        if (status != errorSuccess) {
          throw WindowsAutostartException(
            'RegQueryValueExW($name) 读数据失败：${_describeLstatus(status)}',
            status: status,
          );
        }

        // 第二次调用后 `size` 是实际写入的字节数；仍以第一次问到的 `bytes` 为硬上限，
        // 不信任驱动 / 注册表状态被并发改写后给出的更大值。
        final int written = size.value > bytes ? bytes : size.value;
        final int unitCount = written ~/ 2;
        // 用固定宽度的 Uint16 索引：`Pointer<Utf16>` 不支持 `[]`，而 Uint16 与
        // UTF-16 code unit 的位模式一致。
        final Pointer<Uint16> units = buffer.cast<Uint16>();
        int length = 0;
        while (length < unitCount && units[length] != 0) {
          length++;
        }
        // `length` 已按 unitCount 封顶，转换不会扫描到分配区之外（评审 4）。
        return units.cast<Utf16>().toDartString(length: length);
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(size);
      calloc.free(type);
      malloc.free(wideName);
    }
  }

  /// 删一个值；值本来就不存在也算成功。
  void deleteValue(Pointer<Void> key, String name) {
    final Pointer<Utf16> wideName = name.toNativeUtf16();
    try {
      final int status = _regDeleteValueW(key.address, wideName);
      if (status == errorSuccess || status == errorFileNotFound) return;
      throw WindowsAutostartException(
        'RegDeleteValueW($name) 失败：${_describeLstatus(status)}',
        status: status,
      );
    } finally {
      malloc.free(wideName);
    }
  }

  /// 关掉键；失败只影响后续操作，这里不抛（调用方的主错误更重要）。
  void closeKey(Pointer<Void> key) {
    _regCloseKey(key.address);
  }

  /// LSTATUS → 可读文案；只列已知的几个，其余直写数字。
  static String _describeLstatus(int status) => switch (status) {
    errorAccessDenied => 'LSTATUS 5（拒绝访问）',
    errorMoreData => 'LSTATUS 234（缓冲区不足）',
    _ => 'LSTATUS $status',
  };
}

typedef _RegCreateKeyExWNative =
    Int32 Function(
      IntPtr hKey,
      Pointer<Utf16> subKey,
      Uint32 reserved,
      Pointer<Utf16> className,
      Uint32 options,
      Uint32 access,
      Pointer<Void> securityAttributes,
      Pointer<IntPtr> result,
      Pointer<Uint32> disposition,
    );
typedef _RegCreateKeyExWDart =
    int Function(
      int hKey,
      Pointer<Utf16> subKey,
      int reserved,
      Pointer<Utf16> className,
      int options,
      int access,
      Pointer<Void> securityAttributes,
      Pointer<IntPtr> result,
      Pointer<Uint32> disposition,
    );

typedef _RegOpenKeyExWNative =
    Int32 Function(
      IntPtr hKey,
      Pointer<Utf16> subKey,
      Uint32 options,
      Uint32 access,
      Pointer<IntPtr> result,
    );
typedef _RegOpenKeyExWDart =
    int Function(
      int hKey,
      Pointer<Utf16> subKey,
      int options,
      int access,
      Pointer<IntPtr> result,
    );

typedef _RegSetValueExWNative =
    Int32 Function(
      IntPtr hKey,
      Pointer<Utf16> valueName,
      Uint32 reserved,
      Uint32 type,
      Pointer<Uint8> data,
      Uint32 dataLength,
    );
typedef _RegSetValueExWDart =
    int Function(
      int hKey,
      Pointer<Utf16> valueName,
      int reserved,
      int type,
      Pointer<Uint8> data,
      int dataLength,
    );

typedef _RegQueryValueExWNative =
    Int32 Function(
      IntPtr hKey,
      Pointer<Utf16> valueName,
      Pointer<Uint32> reserved,
      Pointer<Uint32> type,
      Pointer<Uint8> data,
      Pointer<Uint32> dataLength,
    );
typedef _RegQueryValueExWDart =
    int Function(
      int hKey,
      Pointer<Utf16> valueName,
      Pointer<Uint32> reserved,
      Pointer<Uint32> type,
      Pointer<Uint8> data,
      Pointer<Uint32> dataLength,
    );

typedef _RegDeleteValueWNative =
    Int32 Function(IntPtr hKey, Pointer<Utf16> valueName);
typedef _RegDeleteValueWDart = int Function(int hKey, Pointer<Utf16> valueName);

typedef _RegCloseKeyNative = Int32 Function(IntPtr hKey);
typedef _RegCloseKeyDart = int Function(int hKey);

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
