import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
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
    _lastError = _library.lookupFunction<_LastErrorNative, _LastErrorDart>(
      'hax_shot_last_error',
    );
  }

  static const _textBufferCapacity = 4096;
  static final NativeBridge instance = NativeBridge._();

  final DynamicLibrary _library;
  late final _CaptureDart _captureScreen;
  late final _CopyPngDart _copyPng;
  late final _LastErrorDart _lastError;

  /// Runs the blocking Mutter/GStreamer capture call on a worker isolate.
  Future<String> captureScreen() {
    return Isolate.run(() => NativeBridge.instance._captureScreenSync());
  }

  /// Runs the blocking wl-copy process on a worker isolate.
  Future<void> copyPngToClipboard(Uint8List pngBytes) {
    if (pngBytes.isEmpty) {
      throw const NativeBridgeException('PNG 数据为空');
    }
    return Isolate.run(
      () => NativeBridge.instance._copyPngToClipboardSync(pngBytes),
    );
  }

  String _captureScreenSync() {
    final buffer = calloc<Uint8>(_textBufferCapacity);
    try {
      final result = _captureScreen(buffer, _textBufferCapacity);
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
    final candidates = <String>[
      '$executableDirectory/lib/libhax_shot_native.so',
      '$executableDirectory/libhax_shot_native.so',
      'libhax_shot_native.so',
    ];

    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object catch (error) {
        lastError = error;
      }
    }

    throw StateError(
      '找不到 Rust 原生库 libhax_shot_native.so。'
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

typedef _LastErrorNative =
    IntPtr Function(Pointer<Uint8> buffer, IntPtr capacity);
typedef _LastErrorDart = int Function(Pointer<Uint8> buffer, int capacity);

final class NativeBridgeException implements Exception {
  const NativeBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
