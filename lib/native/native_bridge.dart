import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class NativeBridge {
  NativeBridge._() : _library = _openLibrary() {
    try {
      _captureScreen = _library.lookupFunction<_CaptureNative, _CaptureDart>(
        'hax_shot_capture_screen',
      );
      _copyPng = _library.lookupFunction<_CopyPngNative, _CopyPngDart>(
        'hax_shot_copy_png_to_clipboard',
      );
      _cursorDisplay = _library
          .lookupFunction<_CursorDisplayNative, _CursorDisplayDart>(
            'hax_shot_cursor_display',
          );
      _screenCaptureAuthorized = _library
          .lookupFunction<
            _ScreenCaptureAuthorizedNative,
            _ScreenCaptureAuthorizedDart
          >('hax_shot_screen_capture_authorized');
      _requestScreenCaptureAccess = _library
          .lookupFunction<
            _RequestScreenCaptureAccessNative,
            _RequestScreenCaptureAccessDart
          >('hax_shot_request_screen_capture_access');
      _lastError = _library.lookupFunction<_LastErrorNative, _LastErrorDart>(
        'hax_shot_last_error',
      );
      _pngBufferSize = _library
          .lookupFunction<_PngBufferSizeNative, _PngBufferSizeDart>(
            'hax_shot_png_buffer_size',
          );
      _encodePng = _library.lookupFunction<_EncodePngNative, _EncodePngDart>(
        'hax_shot_encode_png',
      );
      // Windows 专用导出（macOS / Linux 的 DLL 里没有这两个符号，不能无条件 lookup）。
      // 顺手把“DLL 是旧版本”这种问题在这一步暴露出来：缺符号的报错会带上已加载的路径。
      if (Platform.isWindows) {
        _targetMonitor = _library
            .lookupFunction<_TargetMonitorNative, _TargetMonitorDart>(
              'hax_shot_target_monitor',
            );
        _lastCaptureTarget = _library
            .lookupFunction<_LastCaptureTargetNative, _LastCaptureTargetDart>(
              'hax_shot_last_capture_target',
            );
      }
    } on ArgumentError catch (error) {
      // 走到这里说明库本体已经加载成功，缺的是导出表里的符号：多半是拷了旧版本的
      // DLL，或者 DLL 的依赖没解析全。把加载成功的路径与原始错误一起带上，
      // 否则现场只能看到 “Failed to lookup symbol” 而不知道是哪个文件。
      throw NativeBridgeException(
        'Rust 原生库已加载（$_loadedLibraryPath），但符号缺失：$error',
      );
    }
  }

  static const _textBufferCapacity = 4096;

  /// rust/src/macos.rs 的 SCREEN_CAPTURE_DENIED：没有屏幕录制授权。
  static const _screenCaptureDeniedCode = -3;

  /// macOS / Linux 的动态库前缀名；Windows 没有 `lib` 前缀，也不放在 `lib/` 下。
  static const _libraryName = 'libhax_shot_native';

  /// 真正加载成功的候选路径：把“符号缺失”定位到具体那个文件用。
  static String _loadedLibraryPath = '';

  static final NativeBridge instance = NativeBridge._();

  final DynamicLibrary _library;
  late final _CaptureDart _captureScreen;
  late final _CopyPngDart _copyPng;
  late final _CursorDisplayDart _cursorDisplay;
  late final _ScreenCaptureAuthorizedDart _screenCaptureAuthorized;
  late final _RequestScreenCaptureAccessDart _requestScreenCaptureAccess;
  late final _LastErrorDart _lastError;
  late final _PngBufferSizeDart _pngBufferSize;
  late final _EncodePngDart _encodePng;

  /// Windows 专用导出（见构造函数；其它平台为 null）。
  _TargetMonitorDart? _targetMonitor;
  _LastCaptureTargetDart? _lastCaptureTarget;

  /// Captures the target display and returns the temporary PNG path.
  ///
  /// Runs the blocking capture call on a worker isolate. Which display is
  /// captured is decided by `--display` (rust/src/macos.rs on macOS,
  /// rust/src/windows.rs on Windows) so it matches the display the Runner puts
  /// the selection overlay on.
  Future<String> captureScreen() {
    return Isolate.run(() => NativeBridge.instance._captureScreenSync());
  }

  /// Copies PNG bytes to the system image clipboard.
  Future<void> copyPngToClipboard(Uint8List pngBytes) {
    if (pngBytes.isEmpty) {
      throw const NativeBridgeException('PNG 数据为空');
    }
    // macOS 的 NSPasteboard 只能在主线程访问；Linux 的 wl-copy 需要等子进程退出，
    // 所以只有 Linux 放到 worker isolate。
    if (Platform.isMacOS) {
      _copyPngToClipboardSync(pngBytes);
      return Future<void>.value();
    }
    return Isolate.run(
      () => NativeBridge.instance._copyPngToClipboardSync(pngBytes),
    );
  }

  /// 用 Rust 把 RGBA8 像素编码成 PNG。
  ///
  /// Skia 的 `Image.toByteData(png)` 走 zlib level 6，实测一张 1920x1080 的截图要
  /// 几百毫秒；Rust 侧用 fdeflate（`png::Compression::Fast`）只要十几毫秒，代价是
  /// 体积大约 +20%，对截图完全值得（实测见 docs/development-guide.md）。
  ///
  /// [pixels] 必须是 width*height*4 个字节、R,G,B,A 顺序、非预乘（PNG 就是非预乘）。
  ///
  /// 编码放在 worker isolate：native 调用是同步的，Retina 选区要几十毫秒，不该卡住
  /// UI 线程（AI 那条路径不会先收起浮层）。
  Future<Uint8List> encodePng(Uint8List pixels, int width, int height) {
    if (width <= 0 || height <= 0) {
      throw const NativeBridgeException('PNG 尺寸非法');
    }
    if (width > 0xFFFFFFFF || height > 0xFFFFFFFF) {
      throw const NativeBridgeException('PNG 尺寸超出原生限制');
    }
    final expected = width * height * 4;
    // 严格相等：多出来的字节说明调用方传错了缓冲区（例如带 stride 的整屏像素），
    // 那样编码出来的图会静默错位。
    if (pixels.length != expected) {
      throw NativeBridgeException(
        '像素字节数不对：${pixels.length}，期望 $expected（width*height*4）',
      );
    }
    return Isolate.run(
      () =>
          NativeBridge.instance._encodePngSync(pixels, width, height, expected),
    );
  }

  Uint8List _encodePngSync(
    Uint8List pixels,
    int width,
    int height,
    int expected,
  ) {
    final capacity = _pngBufferSize(width, height);
    if (capacity <= 0) {
      throw const NativeBridgeException('PNG 尺寸大到无法分配缓冲区');
    }
    final input = calloc<Uint8>(expected);
    final output = calloc<Uint8>(capacity);
    try {
      input.asTypedList(expected).setAll(0, pixels);
      final written = _encodePng(input, width, height, output, capacity);
      if (written < 0) {
        throw NativeBridgeException(_readLastError());
      }
      return Uint8List.fromList(output.asTypedList(written));
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// Whether the app may capture the screen right now.
  ///
  /// macOS 需要用户在“系统设置 → 隐私与安全性 → 屏幕录制”里授权；未授权时截图
  /// 一定失败，所以调用方应该先问这个，再决定是抓屏还是显示授权引导。
  bool screenCaptureAuthorized() => _screenCaptureAuthorized() != 0;

  /// 请求屏幕录制授权（macOS 会弹一次系统对话框）；返回请求后是否已授权。
  ///
  /// 必须在显示引导页之前调用：只有请求过，app 才会出现在“系统设置 → 隐私与
  /// 安全性 → 屏幕录制”的列表里。
  bool requestScreenCaptureAccess() => _requestScreenCaptureAccess() != 0;

  /// Returns the platform identifier of the display under the pointer.
  ///
  /// The tray host reads this once, right when the user asks for a screenshot,
  /// and forwards it to the `--capture` process so the selection overlay and the
  /// native capture target the same display. Returns 0 when the platform cannot
  /// report it (the capture process then falls back to the pointer / main
  /// display, see rust/src/windows.rs).
  int cursorDisplay() => _cursorDisplay();

  /// 查询当前拓扑下本次截图会选中的显示器（`--display` → 光标 → 主屏）。
  ///
  /// 诊断 / 预检用；**摆浮层不能用它**——必须用 [lastCaptureTarget] 返回的冻结结果，
  /// 否则用户在抓屏与摆窗之间换屏时会“抓 A 摆 B”（rust/src/windows.rs 的 §8.5）。
  ///
  /// 只在 Windows 可用；其它平台、或原生报“拿不到目标”（NO_TARGET）时返回 null。
  CaptureTargetMonitor? targetMonitor({int requested = 0}) {
    final lookup = _targetMonitor;
    if (lookup == null) return null;
    if (requested < 0 || requested > 0xFFFFFFFF) {
      throw const NativeBridgeException('requested 超出 u32 范围');
    }
    return _readTargetMonitor(
      'hax_shot_target_monitor',
      (pointer) => lookup(requested, pointer),
    );
  }

  /// 读本进程最近一次成功抓屏**冻结**的目标显示器。
  ///
  /// 返回 null 表示：不是 Windows、还没有成功抓屏过（NO_TARGET），或者冻结的目标已经
  /// 过期（TARGET_STALE：显示器被拔掉 / rect 变了）。后两种情况下都不该再拿旧图摆浮层。
  CaptureTargetMonitor? lastCaptureTarget() {
    final lookup = _lastCaptureTarget;
    if (lookup == null) return null;
    return _readTargetMonitor('hax_shot_last_capture_target', lookup);
  }

  CaptureTargetMonitor? _readTargetMonitor(
    String symbol,
    int Function(Pointer<_NativeTargetMonitor> out) read,
  ) {
    final pointer = calloc<_NativeTargetMonitor>();
    try {
      final code = read(pointer);
      // 1 = NO_TARGET、5 = TARGET_STALE：都是“现在没有可用目标”的正常状态。
      if (code == _targetMonitorNoTarget || code == _targetMonitorStale) {
        return null;
      }
      if (code != _targetMonitorOk) {
        throw NativeBridgeException(
          '$symbol 失败（native code $code）：${_readLastError()}',
        );
      }
      return CaptureTargetMonitor._fromNative(symbol, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  String _captureScreenSync() {
    final buffer = calloc<Uint8>(_textBufferCapacity);
    try {
      final result = _captureScreen(buffer, _textBufferCapacity);
      if (result == _screenCaptureDeniedCode) {
        throw ScreenCapturePermissionException(_readLastError());
      }
      if (result != 0) {
        throw NativeBridgeException(_readLastError());
      }
      return _readCString(buffer, _textBufferCapacity);
    } finally {
      calloc.free(buffer);
    }
  }

  void _copyPngToClipboardSync(Uint8List pngBytes) {
    final buffer = calloc<Uint8>(pngBytes.length);
    try {
      buffer.asTypedList(pngBytes.length).setAll(0, pngBytes);
      final result = _copyPng(buffer, pngBytes.length);
      if (result != 0) {
        throw NativeBridgeException(_readLastError());
      }
    } finally {
      calloc.free(buffer);
    }
  }

  String _readLastError() {
    final buffer = calloc<Uint8>(_textBufferCapacity);
    try {
      _lastError(buffer, _textBufferCapacity);
      final message = _readCString(buffer, _textBufferCapacity);
      return message.isEmpty ? 'Rust 原生操作失败' : message;
    } finally {
      calloc.free(buffer);
    }
  }

  static String _readCString(Pointer<Uint8> pointer, int capacity) {
    final bytes = <int>[];
    for (var index = 0; index < capacity; index++) {
      final value = pointer[index];
      if (value == 0) break;
      bytes.add(value);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 打开 Rust 原生库：按平台列出候选路径，逐个尝试，不依赖当前工作目录。
  ///
  /// 顺序：平台惯例位置（macOS 的 `Contents/Frameworks`、Linux 的 `lib/`）→
  /// exe 旁 → 裸文件名（交给系统自己的搜索规则）。Windows 的第一项就是 exe 旁的
  /// 绝对路径：用户可能从任意目录启动 exe，只看 PATH 会命到别的版本。
  static DynamicLibrary _openLibrary() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final String libraryFileName;
    final List<String> candidates;
    if (Platform.isMacOS) {
      libraryFileName = '$_libraryName.dylib';
      candidates = <String>[
        // Flutter 把 bundle 内的动态库放在 Contents/Frameworks。
        '$executableDirectory/../Frameworks/$libraryFileName',
        '$executableDirectory/$libraryFileName',
        libraryFileName,
      ];
    } else if (Platform.isWindows) {
      libraryFileName = 'hax_shot_native.dll';
      candidates = <String>[
        '$executableDirectory${Platform.pathSeparator}$libraryFileName',
        libraryFileName,
      ];
    } else {
      libraryFileName = '$_libraryName.so';
      candidates = <String>[
        '$executableDirectory/lib/$libraryFileName',
        '$executableDirectory/$libraryFileName',
        libraryFileName,
      ];
    }

    // 汇总**所有**候选取的失败原因，而不是只留最后一条：真正有诊断价值的那条
    // （例如“文件在，但缺依赖 DLL”）可能出现在前面的候选上。
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        final library = DynamicLibrary.open(candidate);
        _loadedLibraryPath = candidate;
        return library;
      } on Object catch (error) {
        failures.add(
          '  $candidate -> ${_describeLoadFailure(candidate, error)}',
        );
      }
    }

    throw StateError(
      '找不到 Rust 原生库 $libraryFileName。'
      '已尝试的路径与失败原因：\n${failures.join('\n')}',
    );
  }

  /// 把 `DynamicLibrary.open` 的失败分成可区分的情况，别把“文件不存在”和
  /// “文件在但加载不了”混成同一句。
  static String _describeLoadFailure(String candidate, Object error) {
    final File file = File(candidate);
    if (!file.isAbsolute) {
      // 裸文件名：Windows 会按 exe 目录 / 系统目录 / PATH 查找，能不能命中由
      // 系统决定，本地 stat 的结果不代表加载器的结果。
      return '按系统搜索规则（exe 目录 / 系统目录 / PATH）未能加载：$error';
    }
    if (!file.existsSync()) {
      return '文件不存在：$candidate';
    }
    return '文件存在但加载失败（通常是缺少依赖 DLL）：$error';
  }
}

typedef _CaptureNative =
    Int32 Function(Pointer<Uint8> outputPath, IntPtr capacity);
typedef _CaptureDart = int Function(Pointer<Uint8> outputPath, int capacity);

typedef _CopyPngNative = Int32 Function(Pointer<Uint8> data, IntPtr length);
typedef _CopyPngDart = int Function(Pointer<Uint8> data, int length);

typedef _ScreenCaptureAuthorizedNative = Uint32 Function();
typedef _ScreenCaptureAuthorizedDart = int Function();

typedef _RequestScreenCaptureAccessNative = Uint32 Function();
typedef _RequestScreenCaptureAccessDart = int Function();

typedef _CursorDisplayNative = Uint32 Function();
typedef _CursorDisplayDart = int Function();

typedef _PngBufferSizeNative = Uint64 Function(Uint32 width, Uint32 height);
typedef _PngBufferSizeDart = int Function(int width, int height);

typedef _EncodePngNative =
    Int32 Function(
      Pointer<Uint8> pixels,
      Uint32 width,
      Uint32 height,
      Pointer<Uint8> output,
      IntPtr capacity,
    );
typedef _EncodePngDart =
    int Function(
      Pointer<Uint8> pixels,
      int width,
      int height,
      Pointer<Uint8> output,
      int capacity,
    );

typedef _LastErrorNative =
    IntPtr Function(Pointer<Uint8> buffer, IntPtr capacity);
typedef _LastErrorDart = int Function(Pointer<Uint8> buffer, int capacity);

typedef _TargetMonitorNative =
    Int32 Function(Uint32 requested, Pointer<_NativeTargetMonitor> out);
typedef _TargetMonitorDart =
    int Function(int requested, Pointer<_NativeTargetMonitor> out);

typedef _LastCaptureTargetNative =
    Int32 Function(Pointer<_NativeTargetMonitor> out);
typedef _LastCaptureTargetDart =
    int Function(Pointer<_NativeTargetMonitor> out);

/// rust/src/windows.rs 的 ABI 错误码（`error_code` 与返回值同一套）。
const int _targetMonitorOk = 0;
const int _targetMonitorNoTarget = 1;
const int _targetMonitorStale = 5;

/// `rust/src/lib.rs` 的 `#[repr(C)] HaxShotTargetMonitor` 的 Dart 布局。
///
/// 字段顺序/对齐必须与 Rust 一致（`u64` 会自己对齐到 8 字节，和 `repr(C)` 相同）。
/// 只读：写入只发生在原生层。
final class _NativeTargetMonitor extends Struct {
  @Uint32()
  external int valid;
  @Uint32()
  external int errorCode;
  @Uint32()
  external int displayId;
  @Uint32()
  external int reserved;
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Uint32()
  external int dpi;
  @Uint64()
  external int generation;
}

/// 一次抓屏目标显示器的元数据（Windows）。
///
/// 由 Rust 计算：`display_id` 是 `MONITORINFOEXW.szDevice` 的 FNV-1a 32 位，rect 是
/// 物理像素（允许为负）。C++ / Dart 只消费，**不要**自己枚举显示器或重算 hash。
final class CaptureTargetMonitor {
  const CaptureTargetMonitor({
    required this.displayId,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.width,
    required this.height,
    required this.dpi,
    required this.generation,
    required this.reserved,
  });

  final int displayId;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final int width;
  final int height;

  /// `GetDpiForMonitor` 的有效 DPI；原生拿不到时是 0。
  final int dpi;

  /// 本次抓屏的代际号（原生侧每成功一次 +1）。
  final int generation;

  /// 原生诊断位（不参与摆位）。
  final int reserved;

  /// 本次抓屏疑似全黑（`reserved` bit 0）：只是告警，不是失败。
  bool get suspectedBlank => reserved & _suspectedBlankFlag != 0;

  /// 采样平均亮度（`reserved` bit 8..15，0..255）。
  int get meanLuma => (reserved >> _meanLumaShift) & 0xFF;

  /// `reserved` 的位域定义，与 rust/src/windows.rs 一致。
  static const _suspectedBlankFlag = 1 << 0;
  static const _meanLumaShift = 8;

  /// 把原生结构体读成 Dart 值对象，并做范围 / 自洽校验。
  ///
  /// 校验失败说明 DLL 与 Dart 侧对不上（旧 DLL 或改错了字段），宁可报错也不要拿一个
  /// 看着合理的数字去摆浮层。
  static CaptureTargetMonitor _fromNative(
    String symbol,
    Pointer<_NativeTargetMonitor> pointer,
  ) {
    final monitor = pointer.ref;
    final displayId = monitor.displayId;
    final width = monitor.width;
    final height = monitor.height;
    if (monitor.valid != 1) {
      throw NativeBridgeException('$symbol 返回的结构体 valid=${monitor.valid}');
    }
    if (monitor.errorCode != _targetMonitorOk) {
      throw NativeBridgeException(
        '$symbol 报 success 但 error_code=${monitor.errorCode}',
      );
    }
    if (displayId == 0) {
      throw NativeBridgeException('$symbol 返回了保留值 display_id=0');
    }
    if (width <= 0 || height <= 0) {
      throw NativeBridgeException('$symbol 返回的尺寸非法：${width}x$height');
    }
    if (monitor.right - monitor.left != width ||
        monitor.bottom - monitor.top != height) {
      throw NativeBridgeException(
        '$symbol 返回的 rect 与尺寸不一致：'
        '(${monitor.left},${monitor.top},${monitor.right},${monitor.bottom}) '
        'vs ${width}x$height',
      );
    }
    return CaptureTargetMonitor(
      displayId: displayId,
      left: monitor.left,
      top: monitor.top,
      right: monitor.right,
      bottom: monitor.bottom,
      width: width,
      height: height,
      dpi: monitor.dpi,
      generation: monitor.generation,
      reserved: monitor.reserved,
    );
  }

  /// 日志用的一行摘要（字段顺序与 docs/development-guide.md 的示例一致）。
  @override
  String toString() {
    return 'display_id=$displayId rect=($left,$top,$right,$bottom) '
        'size=${width}x$height dpi=$dpi generation=$generation';
  }
}

final class NativeBridgeException implements Exception {
  const NativeBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 系统没有授予屏幕录制权限（macOS）。调用方应该显示授权引导，而不是报一个
/// 普通的失败，更不要弹出全屏浮层。
final class ScreenCapturePermissionException extends NativeBridgeException {
  const ScreenCapturePermissionException(super.message);
}
