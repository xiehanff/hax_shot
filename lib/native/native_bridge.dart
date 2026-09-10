import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class NativeBridge {
  NativeBridge._() : _library = _openLibrary() {
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
  }

  static const _textBufferCapacity = 4096;

  /// rust/src/macos.rs 的 SCREEN_CAPTURE_DENIED：没有屏幕录制授权。
  static const _screenCaptureDeniedCode = -3;
  static const _libraryName = 'libhax_shot_native';
  static final NativeBridge instance = NativeBridge._();

  final DynamicLibrary _library;
  late final _CaptureDart _captureScreen;
  late final _CopyPngDart _copyPng;
  late final _CursorDisplayDart _cursorDisplay;
  late final _ScreenCaptureAuthorizedDart _screenCaptureAuthorized;
  late final _RequestScreenCaptureAccessDart _requestScreenCaptureAccess;
  late final _LastErrorDart _lastError;

  /// Captures the target display and returns the temporary PNG path.
  ///
  /// Runs the blocking capture call on a worker isolate. Which display is
  /// captured is decided by `--display` (see rust/src/macos.rs) so it matches
  /// the display the Runner puts the selection overlay on.
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
  /// report it, which means "use the primary display".
  int cursorDisplay() => _cursorDisplay();

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

  static DynamicLibrary _openLibrary() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = Platform.isMacOS
        ? <String>[
            // Flutter 把 bundle 内的动态库放在 Contents/Frameworks。
            '$executableDirectory/../Frameworks/$_libraryName.dylib',
            '$executableDirectory/$_libraryName.dylib',
            '$_libraryName.dylib',
          ]
        : <String>[
            '$executableDirectory/lib/$_libraryName.so',
            '$executableDirectory/$_libraryName.so',
            '$_libraryName.so',
          ];

    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object catch (error) {
        lastError = error;
      }
    }

    final fileName = candidates.last;
    throw StateError(
      '找不到 Rust 原生库 $fileName。'
      '尝试路径：${candidates.join(', ')}。'
      '最后错误：$lastError',
    );
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

typedef _LastErrorNative =
    IntPtr Function(Pointer<Uint8> buffer, IntPtr capacity);
typedef _LastErrorDart = int Function(Pointer<Uint8> buffer, int capacity);

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
