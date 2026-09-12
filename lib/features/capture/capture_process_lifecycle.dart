import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../app/hard_exit.dart';
import '../window/window_visibility.dart';
import 'capture_overlay_window.dart';

/// 抓屏进程与窗口的生命周期 owner：启动浮层、收起/恢复浮层、重启进程、结束进程。
///
/// 真正的抓屏（原生调用 + 解码）留在页面/会话层，这里只管进程与窗口动作，
/// 也不持有任何截图内容。
class CaptureProcessLifecycle {
  CaptureProcessLifecycle({
    required this.targetDisplay,
    required this.onRelaunchError,
  });

  /// 当前进程是从哪块显示器启动的，重启抓屏进程时原样带上。
  final int? targetDisplay;

  /// 重启抓屏进程失败时的上报口（原来落在页面顶层的提示文案上）。
  final void Function(Object error) onRelaunchError;

  /// 正在关闭捕获进程（也刻意不驱动 loading UI）。
  bool _closing = false;

  /// 抓屏成功后启动浮层：把抓屏小窗口升格成铺满屏幕的冻结画面浮层。
  ///
  /// 对应原来 `_capture()` 里属于「启动抓屏进程」的那段收尾；抓屏本身不在这里。
  Future<void> showCaptureOverlay() async {
    await CaptureOverlayWindow.instance.becomeOverlay();
    await showWindow();
    await windowManager.focus();
  }

  /// 收起浮层，让用户不用盯着冻结画面等编码/落盘。
  ///
  /// 实测一张 Retina 尺寸（3024x1964）选区的 PNG 编码约 100~300ms，退出进程还有
  /// 几十毫秒；这些都必须发生在浮层消失之后，否则“保存/复制”看起来就是卡住。
  /// 收起失败也不能中断后续动作，否则用户既没拿到图、窗口也没了。
  Future<void> hideOverlay() async {
    try {
      await windowManager.hide();
    } on Object catch (error) {
      debugPrint('收起浮层失败：$error');
    }
  }

  /// 出错时把浮层放回来，让用户看得见错误信息。
  Future<void> restoreOverlay() async {
    try {
      await windowManager.show();
    } on Object catch (error) {
      debugPrint('恢复浮层失败：$error');
    }
  }

  /// 关闭捕获窗口（Esc / 保存 / 复制 / 取消）。
  ///
  /// 必须走 `windowManager.close()`：关闭请求要交给 `app.dart` 的
  /// `onWindowClose` → `_closeCaptureProcess`，由它关掉 prevent-close、`destroy()`
  /// 再 `exit(0)`；这里直接 exit 会跳过那条收尾链路。
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    // 不要在这里进任何 loading 状态：工具条会因此转圈，而复制/保存之后马上就要
    // 退出进程，用户看到的就是一个没必要的 loading（关闭链路万一没生效还会一直
    // 卡着）。正常路径是 close() → app.dart 的 onWindowClose → destroy + exit(0)；
    // 下面的兜底保证即使那条链路没生效，窗口也不会带着 loading 留在屏幕上。
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        unawaited(exitProcess());
      }),
    );
    await windowManager.close();
  }

  /// 重启一个新的抓屏进程，然后把当前进程结束掉。
  Future<void> relaunch() async {
    try {
      final args = <String>[
        '--capture',
        if (targetDisplay != null) ...['--display', '$targetDisplay'],
      ];
      await Process.start(
        Platform.resolvedExecutable,
        args,
        mode: ProcessStartMode.detached,
      );
      await exitProcess();
    } on Object catch (error) {
      onRelaunchError(error);
    }
  }

  /// 结束当前捕获进程。
  ///
  /// 用硬退出（见 features/app/hard_exit.dart）：`exit(0)` 在 macOS 上会挂在引擎
  /// 收尾里，进程会残留；`windowManager.destroy()` 又要多等几百毫秒。
  Future<void> exitProcess() async {
    exitProcessNow();
  }
}
