import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../native/native_bridge.dart';
import '../settings/screen_capture_permission.dart';
import '../window/window_visibility.dart';

/// 抓屏尝试的状态与权限流程的唯一 owner。
///
/// 负责：抓屏前的屏幕录制授权预检、缺权限时的引导页状态、平台无关的失败态、
/// 等待授权期间的轮询，以及页面顶层的提示文案。
///
/// [loading] 也放在这里：它和 [needsPermission] / [failureMessage] / [message]
/// 一起决定页面顶层渲染哪一块（引导页 / 失败面板 / loading / 浮层），拆成两半会
/// 让这套模式判断跨文件。
///
/// 页面只通过 [notifyListeners] 跟着重建；需要页面的动作（重新抓屏、重启抓屏进程、
/// 关闭进程、判断平台）全部靠构造参数注入的回调回到页面。
class CapturePermissionFlow extends ChangeNotifier {
  CapturePermissionFlow({
    required this.onRetryCapture,
    required this.onRelaunchCaptureProcess,
    required this.onQuit,
    required this.isMacOS,
  });

  /// 引导页 / 失败面板「重试」时重新抓屏的入口（页面的 `_capture()`）。
  final Future<void> Function() onRetryCapture;

  /// 重启一个新的抓屏进程：macOS 的抓屏授权按进程缓存，必须换进程才读得到新授权。
  final Future<void> Function() onRelaunchCaptureProcess;

  /// 关闭捕获进程（引导页的「关闭」）。
  final VoidCallback onQuit;

  /// 当前平台是否 macOS（决定引导页给不给「重置授权记录」入口）。
  final bool Function() isMacOS;

  /// 等待授权期间的轮询：和 hax_pick 一样，授权成功后自动继续，不需要用户点按钮。
  ///
  /// 注意 macOS 抓屏授权是**按进程缓存**的，所以这里检测到已授权后不是原地继续，
  /// 而是重启一个新的抓屏进程（新进程才读得到新授权）。
  Timer? _permissionPoll;
  static const _permissionPollInterval = Duration(milliseconds: 750);

  bool _disposed = false;

  bool _loading = true;

  /// 两种状态互斥，模式切换的写入点只有 [showGuide] 与 [enterFailure] 两处：
  /// - [needsPermission] = 缺屏幕录制权限 → 走 macOS 语义的授权引导页；
  /// - [failureMessage] = 普通失败（含「授权查询本身失败」）→ 走平台无关的失败面板。
  ///
  /// 两种情况都必须留在小窗口里：用户可能还没授权，如果把全屏浮层弹出来，
  /// 整块屏幕会被盖住，连菜单栏都点不到。
  bool _needsPermission = false;

  String? _message;

  /// 非权限类失败的说明文案；非 null 时页面渲染平台无关的失败面板。
  String? _failureMessage;

  bool get loading => _loading;

  bool get needsPermission => _needsPermission;

  String? get message => _message;

  String? get failureMessage => _failureMessage;

  /// 引导页的「重置授权记录」入口；非 macOS 平台上为 null（页面上就没有这个动作）。
  Future<void> Function()? get resetPermissionAction =>
      isMacOS() ? resetPermission : null;

  /// 页面其它流程（AI / 保存 / 复制 / 选区提示）设置顶层文案的入口。
  void showMessage(String? message) {
    _update(() => _message = message);
  }

  /// 抓屏前的授权预检：返回 true 表示可以继续抓屏；false 表示已经进了引导页
  /// 或失败面板，调用方直接返回即可。
  Future<bool> allowCapture() async {
    final authorized = screenCaptureAuthorizedSafe();
    if (authorized == null) {
      enterFailure(_authorizationQueryFailure);
      await revealWindow();
      return false;
    }
    if (!authorized) {
      await showGuide();
      return false;
    }
    return true;
  }

  /// 抓屏成功的收尾：清掉三种状态并把轮询停下。
  void markCaptureSucceeded() {
    _stopPermissionPolling();
    _update(() {
      _loading = false;
      _message = null;
      _needsPermission = false;
      _failureMessage = null;
    });
  }

  /// 查询屏幕录制授权；返回 null 表示**查询本身失败**（dylib 缺失 / 符号问题）。
  ///
  /// 返回 null 时调用方必须进平台无关的失败面板：这既不能当成「没授权」（会掉进
  /// macOS 专属的授权引导页），也不能当成「已授权」（会直接去抓屏然后失败）。
  bool? screenCaptureAuthorizedSafe() {
    try {
      return NativeBridge.instance.screenCaptureAuthorized();
    } on Object catch (error) {
      debugPrint('查询屏幕录制授权失败：$error');
      return null;
    }
  }

  /// 进入平台无关的失败态。与 [showGuide] 互斥，两者是 [needsPermission] /
  /// [failureMessage] 仅有的两个模式切换写入点。
  void enterFailure(Object error) {
    _stopPermissionPolling();
    _update(() {
      _loading = false;
      _needsPermission = false;
      _message = null;
      _failureMessage = '截图失败：$error';
    });
  }

  /// 把抓屏用的小窗口显示出来并聚焦。
  ///
  /// 两步各自兜底：引导页与失败路径都不能把异常抛给调用方，这些调用点多来自
  /// postFrameCallback / 定时器，抛出去就是未捕获异步异常。
  ///
  /// 这里不往页面要回调：它就是两次全局 window_manager 调用，不依赖页面任何状态。
  Future<void> revealWindow() async {
    try {
      await showWindow();
    } on Object catch (error) {
      debugPrint('显示窗口失败：$error');
    }
    try {
      await windowManager.focus();
    } on Object catch (error) {
      debugPrint('聚焦窗口失败：$error');
    }
  }

  /// 原生库查不到授权状态时的失败说明（安全查询返回 null）。
  static const _authorizationQueryFailure = '无法查询屏幕录制授权（原生库未加载或符号缺失）';

  /// 等待授权时的轮询回调：已授权就重启抓屏进程继续截图。
  Future<void> checkPermissionWhileWaiting() async {
    if (_disposed || !_needsPermission) return;
    try {
      final authorized = screenCaptureAuthorizedSafe();
      if (authorized == null) {
        enterFailure(_authorizationQueryFailure);
        await revealWindow();
        return;
      }
      if (!authorized) return;
      _stopPermissionPolling();
      _update(() => _message = '检测到已授权，正在继续…');
      await onRelaunchCaptureProcess();
    } on Object catch (error) {
      debugPrint('检查屏幕录制授权失败：$error');
    }
  }

  /// 缺屏幕录制权限时显示引导页：普通小窗口，随时可以关掉。
  ///
  /// 这是 [needsPermission] / [failureMessage] 两个模式切换写入点之一。
  /// 本方法对两个调用点都不抛异常：授权请求失败时**留在引导页**并把错误当作
  /// 说明文案（“当前进程没有屏幕录制授权”这个判断仍然成立，系统设置的出口仍有用）；
  /// 失败面板只留给「授权查询本身失败」这种平台无关的情况。
  Future<void> showGuide({String? message}) async {
    var guideMessage = message;
    try {
      // 触发一次系统授权请求：这样 Hax Shot 才会出现在“屏幕录制”列表里，
      // 用户点“打开系统设置”才能找到它。用户确认前返回值是 false。
      NativeBridge.instance.requestScreenCaptureAccess();
    } on Object catch (error) {
      final hint = '请求屏幕录制授权失败：$error';
      guideMessage = guideMessage == null ? hint : '$guideMessage\n$hint';
    }
    _startPermissionPolling();
    _update(() {
      _loading = false;
      _needsPermission = true;
      _failureMessage = null;
      _message = guideMessage;
    });
    await revealWindow();
  }

  /// 引导页的“我已授权，重新检查”与失败面板的“重试”共用这个入口（轮询已经能自动发现，
  /// 这里保留手动入口）。
  ///
  /// macOS 会把 TCC 结果缓存到进程结束，所以刚授权完这个进程通常还认为没权限；
  /// 直接原地重试会一直失败。这里改成**重启一个新的抓屏进程**（新进程重新读授权
  /// 状态），当前进程随即退出，用户只需要点一次。
  Future<void> retryAfterPermission() async {
    final authorized = screenCaptureAuthorizedSafe();
    if (authorized == null) {
      // 查询本身失败：不管从引导页还是失败面板点的重试，都只落失败面板。
      enterFailure(_authorizationQueryFailure);
      await revealWindow();
      return;
    }
    if (authorized) {
      // 先清掉上一次的文案：重试期间不应该还挂着旧失败面板（或旧引导说明）。
      _update(() {
        _loading = true;
        _message = null;
        _failureMessage = null;
      });
      await onRetryCapture();
      return;
    }

    await onRelaunchCaptureProcess();
  }

  /// 重置系统的屏幕录制授权记录，然后重启抓屏进程重新申请授权。
  ///
  /// 针对“系统设置里开关是开的，但当前进程没有权限、也不再弹授权框”的死结：
  /// 本地 ad-hoc 签名每次构建都会换指纹，旧记录和新二进制对不上。
  Future<void> resetPermission() async {
    _stopPermissionPolling();
    try {
      await ScreenCapturePermission.instance.reset();
    } on Object catch (error) {
      _update(() => _message = '重置授权记录失败：$error');
      return;
    }
    await onRelaunchCaptureProcess();
  }

  /// 引导页的「关闭」，交回页面注入的进程关闭动作。
  void quit() => onQuit();

  @override
  void dispose() {
    _disposed = true;
    _stopPermissionPolling();
    super.dispose();
  }

  void _startPermissionPolling() {
    _permissionPoll ??= Timer.periodic(
      _permissionPollInterval,
      (_) => unawaited(checkPermissionWhileWaiting()),
    );
  }

  void _stopPermissionPolling() {
    _permissionPoll?.cancel();
    _permissionPoll = null;
  }

  void _update(void Function() change) {
    change();
    if (_disposed) return;
    notifyListeners();
  }
}
