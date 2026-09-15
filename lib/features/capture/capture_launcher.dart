import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../diagnostics/diagnostic_events.dart';
import '../diagnostics/diagnostic_log.dart';
import 'capture_request_channel.dart';

/// 截图是由谁触发的。菜单和全局快捷键必须走同一条启动链，只在这个字段上区分。
enum CaptureTriggerSource {
  shortcut,
  trayMenu,
  settings;

  /// 触发瞬间记录的事件名。
  String get triggerEvent => switch (this) {
    CaptureTriggerSource.shortcut => DiagnosticEvent.shortcutTrigger,
    CaptureTriggerSource.trayMenu => DiagnosticEvent.menuCaptureTrigger,
    CaptureTriggerSource.settings => DiagnosticEvent.settingsCaptureTrigger,
  };

  String get logValue => switch (this) {
    CaptureTriggerSource.shortcut => 'shortcut',
    CaptureTriggerSource.trayMenu => 'tray_menu',
    CaptureTriggerSource.settings => 'settings',
  };
}

/// 启动结果的高层分类（见 docs/development-guide.md §12.2）。
enum CaptureLaunchStatus {
  started,
  lockBusy,
  spawnFailed,
  startupTimeout,
  startupFailed,
}

/// 启动被拒绝的原因（不是崩溃，是并发/超时等可解释状态）。
enum CaptureRejectReason { lockBusy, startupTimeout, childStartupFailed }

/// 一次启动尝试的结果。
sealed class CaptureLaunchResult {
  const CaptureLaunchResult({required this.requestId});

  /// 本次请求的 id；连 requestId 都还没生成时（理论上不会有）为空。
  final String? requestId;
}

final class CaptureLaunchStarted extends CaptureLaunchResult {
  const CaptureLaunchStarted({required super.requestId, this.pid});

  /// 子进程 pid；spawn 成功时一定有。
  final int? pid;

  CaptureLaunchStatus get status => CaptureLaunchStatus.started;
}

final class CaptureLaunchRejected extends CaptureLaunchResult {
  const CaptureLaunchRejected({required super.requestId, required this.reason});

  final CaptureRejectReason reason;

  CaptureLaunchStatus get status => switch (reason) {
    CaptureRejectReason.lockBusy => CaptureLaunchStatus.lockBusy,
    CaptureRejectReason.startupTimeout => CaptureLaunchStatus.startupTimeout,
    CaptureRejectReason.childStartupFailed => CaptureLaunchStatus.startupFailed,
  };
}

final class CaptureLaunchFailed extends CaptureLaunchResult {
  const CaptureLaunchFailed({
    required super.requestId,
    required this.status,
    required this.error,
    this.errorCode,
  });

  final CaptureLaunchStatus status;
  final Object error;
  final String? errorCode;
}

/// 启动 `--capture` 子进程并确认它真的进入了截图启动链。
///
/// 职责边界：requestId、参数、`Process.start`、ACK 轮询、结果与日志。**不**包含
/// 截图算法、浮层、标注、导出——那些仍在各自的类里。
final class CaptureLauncher {
  CaptureLauncher({
    CaptureRequestChannel? channel,
    DiagnosticLogService? log,
    Future<Process> Function(String executable, List<String> arguments)?
    starter,
    this.ackTimeout = const Duration(milliseconds: 1500),
    this.pollInterval = const Duration(milliseconds: 40),
    String? executablePath,
    Random? random,
  }) : _channel = channel ?? CaptureRequestChannel.instance,
       _log = log ?? DiagnosticLogService.instance,
       _starter = starter ?? _defaultStarter,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _random = random ?? Random();

  /// 宿主最多等这么久拿到 `child_started` / `lock_acquired`。
  ///
  /// 只等启动阶段（不是等用户画完选框）：正常机器上从 spawn 到拿到锁是几十毫秒，
  /// 1.5s 已经足够宽松；超时只是说明“没确认”，不代表失败（见 [CaptureLaunchRejected]）。
  final Duration ackTimeout;
  final Duration pollInterval;

  final CaptureRequestChannel _channel;
  final DiagnosticLogService _log;
  final Future<Process> Function(String, List<String>) _starter;
  final String _executablePath;
  final Random _random;

  /// single-flight：一次只允许一个启动尝试在飞。
  ///
  /// 快速连按快捷键时不启动 5 个进程：后来的请求直接按 lockBusy 拒绝并记日志
  /// （详见 docs/development-guide.md §“Rapid Trigger”）。
  bool _launching = false;

  bool get isLaunching => _launching;

  static Future<Process> _defaultStarter(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments, mode: ProcessStartMode.detached);

  /// 启动一次截图，返回可直接用于诊断的结果。
  ///
  /// [displayArguments] 形如 `['--display', '3']`，由触发方在“用户按下的那一刻”
  /// 取好（见 docs/development-guide.md 6.9）。
  Future<CaptureLaunchResult> launch({
    required CaptureTriggerSource source,
    List<String> displayArguments = const <String>[],
  }) async {
    final requestId = newRequestId();
    // 每一次触发都要留下 shortcut_trigger / menu_capture_trigger，与被拒绝的请求
    // 无关：否则“按下没反应”时连一层证据都没有。
    _log.log(
      source.triggerEvent,
      requestId: requestId,
      source: source.logValue,
    );

    if (_launching) {
      _log.log(
        DiagnosticEvent.captureLaunchRejected,
        level: LogLevel.info,
        requestId: requestId,
        source: source.logValue,
        errorCode: DiagnosticErrorCode.captureLockBusy,
        message: '已有一次截图请求正在启动，忽略本次触发',
        extra: <String, Object?>{'reason': 'in_flight'},
      );
      return CaptureLaunchRejected(
        requestId: requestId,
        reason: CaptureRejectReason.lockBusy,
      );
    }

    _launching = true;
    try {
      return await _launch(
        requestId: requestId,
        source: source,
        displayArguments: displayArguments,
      );
    } finally {
      _launching = false;
      // 每次触发顺手清一次过期请求文件：宿主可能连续跑几天，只在启动时清会一直涨。
      try {
        _channel.cleanupExpired();
      } on Object {
        // 清理失败不影响截图。
      }
    }
  }

  Future<CaptureLaunchResult> _launch({
    required String requestId,
    required CaptureTriggerSource source,
    required List<String> displayArguments,
  }) async {
    // 必须同步写：异步写会在子进程已经写下 `child_started` 之后才落盘，
    // 把更新的状态覆盖回 `created`。
    _channel.writeStateSync(
      requestId,
      CaptureRequestChannel.stateCreated,
      extra: <String, Object?>{'source': source.logValue, 'host_pid': pid},
    );
    _log.log(
      DiagnosticEvent.captureRequestCreated,
      requestId: requestId,
      source: source.logValue,
    );

    final arguments = <String>[
      '--capture',
      '--request-id',
      requestId,
      '--trigger-source',
      source.logValue,
      ...displayArguments,
    ];

    _log.log(
      DiagnosticEvent.captureSpawnStart,
      requestId: requestId,
      source: source.logValue,
      extra: <String, Object?>{'executable': _executablePath},
    );

    Process process;
    try {
      process = await _starter(_executablePath, arguments);
    } on Object catch (error) {
      _log.log(
        DiagnosticEvent.captureSpawnFailed,
        level: LogLevel.error,
        requestId: requestId,
        source: source.logValue,
        errorCode: DiagnosticErrorCode.captureProcessSpawnFailed,
        message: '$error',
      );
      _channel.writeStateSync(
        requestId,
        CaptureRequestChannel.stateStartupFailed,
        extra: <String, Object?>{'error': '$error'},
      );
      return CaptureLaunchFailed(
        requestId: requestId,
        status: CaptureLaunchStatus.spawnFailed,
        error: error,
        errorCode: DiagnosticErrorCode.captureProcessSpawnFailed,
      );
    }

    _log.log(
      DiagnosticEvent.captureSpawnSuccess,
      requestId: requestId,
      source: source.logValue,
      extra: <String, Object?>{'child_pid': process.pid},
    );

    final result = await _awaitAcknowledgement(
      requestId: requestId,
      source: source,
      childPid: process.pid,
    );
    return result;
  }

  /// 轮询请求文件，直到子进程报告拿到锁（或明确的失败态），或者超时。
  ///
  /// 宿主**自己**把观察到的阶段也记一遍日志：这样宿主日志单独就能串出完整链路
  ///（spawn → child_started → lock_acquired），不用去翻子进程的 `pid` 找那一行。
  Future<CaptureLaunchResult> _awaitAcknowledgement({
    required String requestId,
    required CaptureTriggerSource source,
    required int childPid,
  }) async {
    final deadline = DateTime.now().add(ackTimeout);
    var childStarted = false;

    while (DateTime.now().isBefore(deadline)) {
      final state = _channel.readStateName(requestId);
      switch (state) {
        case CaptureRequestChannel.stateLockAcquired:
        case CaptureRequestChannel.stateCaptureReady:
          _log.log(
            DiagnosticEvent.captureLockAcquired,
            requestId: requestId,
            source: source.logValue,
            extra: <String, Object?>{
              'observed_by': 'host',
              'child_pid': childPid,
            },
          );
          return CaptureLaunchStarted(requestId: requestId, pid: childPid);
        case CaptureRequestChannel.stateLockBusy:
          return CaptureLaunchRejected(
            requestId: requestId,
            reason: CaptureRejectReason.lockBusy,
          );
        case CaptureRequestChannel.stateStartupFailed:
          final payload = _channel.readState(requestId);
          final message = payload?['error']?.toString() ?? '子进程报告启动失败';
          _log.log(
            DiagnosticEvent.captureStartupFailed,
            level: LogLevel.error,
            requestId: requestId,
            source: source.logValue,
            errorCode: DiagnosticErrorCode.captureStartupFailed,
            message: message,
          );
          return CaptureLaunchFailed(
            requestId: requestId,
            status: CaptureLaunchStatus.startupFailed,
            error: StateError(message),
            errorCode: DiagnosticErrorCode.captureStartupFailed,
          );
        case CaptureRequestChannel.stateChildStarted:
          if (!childStarted) {
            childStarted = true;
            _log.log(
              DiagnosticEvent.captureChildStarted,
              requestId: requestId,
              source: source.logValue,
              extra: <String, Object?>{
                'observed_by': 'host',
                'child_pid': childPid,
              },
            );
          }
        default:
          break;
      }
      await Future<void>.delayed(pollInterval);
    }

    // 超时只说明宿主没在预期时间内拿到确认；**不** kill 子进程，它可能只是慢。
    _log.log(
      DiagnosticEvent.captureLaunchTimeout,
      level: LogLevel.warning,
      requestId: requestId,
      source: source.logValue,
      errorCode: DiagnosticErrorCode.captureChildTimeout,
      message: childStarted
          ? '子进程已启动但未在 ${ackTimeout.inMilliseconds}ms 内确认取得捕获锁'
          : '子进程未在 ${ackTimeout.inMilliseconds}ms 内确认启动',
      extra: <String, Object?>{
        'child_pid': childPid,
        'child_started': childStarted,
      },
    );
    return CaptureLaunchRejected(
      requestId: requestId,
      reason: childStarted
          ? CaptureRejectReason.startupTimeout
          : CaptureRejectReason.childStartupFailed,
    );
  }

  /// `yyyyMMdd-HHmmss-xxxx`：够用来把宿主和子进程的日志串起来，不引入 UUID 依赖。
  String newRequestId() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final suffix = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '$stamp-$suffix';
  }
}
