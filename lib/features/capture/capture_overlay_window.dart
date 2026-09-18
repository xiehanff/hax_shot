import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 一次成功的 `becomeOverlay` 的原生摆位结果（Windows，§14.8）。
///
/// macOS 的桥与 Linux 的 `setFullScreen` 都没有这个形状，所以只有 Windows 上非 null。
final class CaptureOverlayPlacement {
  const CaptureOverlayPlacement({
    required this.displayId,
    required this.generation,
    required this.clientRect,
    required this.dpi,
  });

  /// 冻结元数据里的 display id（`szDevice` 的 FNV-1a 32 位）。
  final int displayId;

  /// 本次抓屏的代际号（与 PNG 配对）。
  final int generation;

  /// 原生 `GetClientRect` 的结果，**物理像素**；overlay 态下必须等于目标 rcMonitor
  /// 的宽高（§13.5 的硬判据）。
  final Rect clientRect;

  /// 原生窗口的 DPI 来自 `GetDpiForWindow`；拿不到时退回冻结元数据的 dpi（0 也行）。
  final int dpi;

  /// 解析原生返回值。形状不对说明 DLL / 桥与 Dart 侧对不上，宁可报错也不拿一个
  /// 看着合理的 rect 去摆浮层。
  static CaptureOverlayPlacement parse(Object? payload) {
    if (payload is! Map) {
      throw const CaptureOverlayException(
        code: 'INVALID_ARGUMENT',
        message: '浮层桥没有返回摆位结果',
      );
    }
    final Object? client = payload['clientRect'];
    if (client is! Map) {
      throw const CaptureOverlayException(
        code: 'INVALID_ARGUMENT',
        message: '浮层桥返回的 clientRect 形状不对',
      );
    }
    return CaptureOverlayPlacement(
      displayId: _readInt(payload['displayId'], 'displayId'),
      generation: _readInt(payload['generation'], 'generation'),
      clientRect: Rect.fromLTRB(
        _readInt(client['left'], 'clientRect.left').toDouble(),
        _readInt(client['top'], 'clientRect.top').toDouble(),
        _readInt(client['right'], 'clientRect.right').toDouble(),
        _readInt(client['bottom'], 'clientRect.bottom').toDouble(),
      ),
      dpi: _readInt(payload['dpi'], 'dpi'),
    );
  }

  static int _readInt(Object? value, String field) {
    if (value is int) return value;
    if (value is double && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw CaptureOverlayException(
      code: 'INVALID_ARGUMENT',
      message: '浮层桥返回的 $field 不是整数：$value',
    );
  }

  @override
  String toString() =>
      'display_id=$displayId generation=$generation '
      'client=(${clientRect.left.toInt()},${clientRect.top.toInt()},'
      '${clientRect.right.toInt()},${clientRect.bottom.toInt()}) dpi=$dpi';
}

/// `becomeOverlay` 失败时的可读错误：带原生错误码（§8.4，例如 5 = TARGET_STALE）。
///
/// 与 [NativeBridgeException] 分开：这个只代表“浮层没摆好”，调用方必须走失败面板，
/// 不允许退回主屏全屏（§15.2）。
final class CaptureOverlayException implements Exception {
  const CaptureOverlayException({
    required this.code,
    required this.message,
    this.details,
  });

  factory CaptureOverlayException.fromPlatformException(
    PlatformException error,
  ) {
    return CaptureOverlayException(
      code: error.code,
      message: error.message ?? '原生浮层桥返回了空消息',
      details: error.details,
    );
  }

  /// 原生错误码文本（§8.4 的 0..7）。
  final String code;

  /// 可读原因（原生 message）。
  final String message;

  /// 原生附带的细节（本轮为 null）。
  final Object? details;

  @override
  String toString() => '浮层切换失败（native code $code）：$message';
}

/// 把捕获进程的窗口升格成冻结画面浮层。
///
/// 捕获进程启动时只是一个普通小窗口，抓屏失败时用户看到的是小窗口里的提示；
/// 只有抓到画面之后才调用 [becomeOverlay] 铺满目标显示器。
final class CaptureOverlayWindow {
  CaptureOverlayWindow({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('hax_shot/capture_window'),
      _enabled =
          enabled ?? ((Platform.isMacOS || Platform.isWindows) && !kIsWeb);

  static final instance = CaptureOverlayWindow();

  final MethodChannel _channel;
  final bool _enabled;

  /// Windows：浮层摆位由原生桥完成（参数与返回值见 §14.8）。
  ///
  /// 其它平台 [becomeOverlay] 也走原生层，但 `enableResizablePanel` 仍然留给
  /// `window_manager`（§14.6：普通面板的尺寸/层级/可缩放不归浮层桥管）。
  bool get _usesWindowsOverlay => _enabled && Platform.isWindows && !kIsWeb;

  /// 退出浮层状态：恢复普通窗口层级并关掉全屏。
  ///
  /// AI 面板接管同一个窗口之前必须走这里，否则窗口可能停在
  /// “全屏 + .screenSaver 层级”——菜单栏点不到、Esc 也退不出去。
  Future<void> exitOverlay() async {
    if (_enabled) {
      // macOS 只有原生层能恢复 `.screenSaver` level/collectionBehavior；Windows 只有
      // 原生桥能恢复 overlay 前的 style / rect / topmost（§14.5）。失败时必须
      // 向上传播，调用方不能误以为已经安全退出并释放捕获锁。
      await _channel.invokeMethod<void>('exitOverlay');
      return;
    }
    await windowManager.setFullScreen(false);
  }

  /// 把窗口切成「可拖动边缘改大小的面板」。
  ///
  /// 必须走原生：macOS 的 `styleMask` 由 Runner 整块赋值，`window_manager` 的
  /// `setResizable` 插完 `.resizable` 之后 AppKit 会把系统自带的红黄绿按钮重新显示
  /// 出来，和面板右上角 Flutter 自己画的关闭按钮重复。只有原生层能在同一步里
  /// 「插 .resizable + 再藏一遍按钮」。
  ///
  /// Windows 不走原生桥：普通面板本来就带 `WS_THICKFRAME`，而且 overlay 退出后
  /// 窗口交还 `window_manager`（§14.6）。原生桥保留了同名方法只为接口一致。
  Future<void> enableResizablePanel() async {
    if (_enabled && Platform.isMacOS) {
      await _channel.invokeMethod<void>('enableResizablePanel');
      return;
    }
    await windowManager.setResizable(true);
  }

  /// 让窗口盖住目标显示器（macOS 由 Runner 设置窗口层级）。
  ///
  /// Windows：原生桥读**冻结**的目标元数据摆位，只配置不显示，最后由 Dart 的
  /// `showWindow()` 显示；失败抛 [CaptureOverlayException]，**不允许** fallback 到
  /// 主屏全屏（§15.2，那会造成“抓了 A 屏、浮层全屏在主屏”的假成功）。
  ///
  /// macOS：保持原有 fallback 语义（原生失败就退回 `setFullScreen(true)`）。
  Future<CaptureOverlayPlacement?> becomeOverlay({
    int? targetDisplay,
    int? generation,
  }) async {
    if (_usesWindowsOverlay) {
      final Object? payload;
      try {
        payload = await _channel.invokeMethod<Object?>(
          'becomeOverlay',
          <String, Object?>{
            // 0 的含义是“未指定”（§8.2）：桥会跳过一致性校验，直接用冻结元数据。
            'displayId': targetDisplay ?? 0,
            'generation': generation ?? 0,
          },
        );
      } on PlatformException catch (error) {
        // 桥在、但 DLL / 元数据 / 摆位失败：带 §8.4 的 code（§15.5 b）。
        // MissingPluginException 不在这里被吞（§15.5 a）。
        throw CaptureOverlayException.fromPlatformException(error);
      }
      return CaptureOverlayPlacement.parse(payload);
    }
    if (_enabled) {
      try {
        await _channel.invokeMethod<void>('becomeOverlay');
        return null;
      } on Object catch (error) {
        debugPrint('切换浮层失败：$error');
      }
    }
    // 其它平台用 Flutter 自己的全屏（窗口此时仍然隐藏，等 show() 才出现）。
    await windowManager.setFullScreen(true);
    return null;
  }
}
