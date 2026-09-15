import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/capture/capture_launcher.dart';
import 'package:hax_shot/features/capture/capture_request_channel.dart';
import 'package:hax_shot/features/diagnostics/diagnostic_log.dart';

/// 假子进程：只在测试里被记录，真正的 `--capture` 不会被启动。
final class _FakeProcess implements Process {
  @override
  int get pid => 4242;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late CaptureRequestChannel channel;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('hax_shot_launcher_test');
    channel = CaptureRequestChannel(directory: directory);
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on Object {
      // 忽略清理失败。
    }
  });

  CaptureLauncher launcher({
    Future<Process> Function(String, List<String>)? starter,
    Duration ackTimeout = const Duration(milliseconds: 120),
    Duration pollInterval = const Duration(milliseconds: 5),
  }) => CaptureLauncher(
    channel: channel,
    log: DiagnosticLogService(directory: directory),
    starter: starter ?? (_, _) async => _FakeProcess(),
    ackTimeout: ackTimeout,
    pollInterval: pollInterval,
    executablePath: '/tmp/hax_shot',
  );

  test('spawn 抛异常时返回 spawnFailed', () async {
    final result = await launcher(
      starter: (_, _) async =>
          throw const ProcessException('/tmp/hax_shot', <String>[]),
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(result, isA<CaptureLaunchFailed>());
    final failed = result as CaptureLaunchFailed;
    expect(failed.status, CaptureLaunchStatus.spawnFailed);
    expect(failed.errorCode, 'CAPTURE_PROCESS_SPAWN_FAILED');
    expect(failed.requestId, isNotNull);
  });

  test('子进程报告 lock_acquired 时返回 started', () async {
    final result = await launcher(
      starter: (_, arguments) async {
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateChildStarted,
        );
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateLockAcquired,
        );
        return _FakeProcess();
      },
    ).launch(source: CaptureTriggerSource.trayMenu);

    expect(result, isA<CaptureLaunchStarted>());
    expect((result as CaptureLaunchStarted).pid, 4242);
  });

  test('子进程报告 lock_busy 时按 lockBusy 拒绝', () async {
    final result = await launcher(
      starter: (_, arguments) async {
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        channel.writeStateSync(requestId, CaptureRequestChannel.stateLockBusy);
        return _FakeProcess();
      },
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(result, isA<CaptureLaunchRejected>());
    expect(
      (result as CaptureLaunchRejected).reason,
      CaptureRejectReason.lockBusy,
    );
  });

  test('子进程报告 startup_failed 时返回 startupFailed', () async {
    final result = await launcher(
      starter: (_, arguments) async {
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateStartupFailed,
          extra: <String, Object?>{'error': '原生库加载失败'},
        );
        return _FakeProcess();
      },
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(result, isA<CaptureLaunchFailed>());
    expect(
      (result as CaptureLaunchFailed).status,
      CaptureLaunchStatus.startupFailed,
    );
  });

  test('子进程起了但一直不 ACK → startupTimeout（不杀进程）', () async {
    final result = await launcher(
      starter: (_, arguments) async {
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateChildStarted,
        );
        return _FakeProcess();
      },
      ackTimeout: const Duration(milliseconds: 60),
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(result, isA<CaptureLaunchRejected>());
    expect(
      (result as CaptureLaunchRejected).reason,
      CaptureRejectReason.startupTimeout,
    );
  });

  test('子进程完全没起来（没有任何 ACK）→ childStartupFailed', () async {
    final result = await launcher(
      ackTimeout: const Duration(milliseconds: 60),
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(result, isA<CaptureLaunchRejected>());
    expect(
      (result as CaptureLaunchRejected).reason,
      CaptureRejectReason.childStartupFailed,
    );
  });

  test('请求文件按 requestId 更新，状态可被读回', () async {
    final seen = <String>[];
    await launcher(
      starter: (_, arguments) async {
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        seen.add(requestId);
        expect(
          channel.readStateName(requestId),
          CaptureRequestChannel.stateCreated,
        );
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateLockAcquired,
        );
        return _FakeProcess();
      },
    ).launch(source: CaptureTriggerSource.shortcut);

    expect(seen, hasLength(1));
    expect(seen.single, matches(RegExp(r'^\d{8}-\d{6}-[0-9a-f]{4}$')));
  });

  test('连续两次 launch 的 requestId 不同', () async {
    final launcherInstance = launcher();
    final first = await launcherInstance.launch(
      source: CaptureTriggerSource.shortcut,
    );
    final second = await launcherInstance.launch(
      source: CaptureTriggerSource.shortcut,
    );
    expect(first.requestId, isNot(second.requestId));
  });

  test('同时触发时第二次直接按 lockBusy 拒绝，不启动第二个进程', () async {
    var spawned = 0;
    final gate = Completer<void>();
    final launcherInstance = launcher(
      starter: (_, arguments) async {
        spawned++;
        final requestId = arguments[arguments.indexOf('--request-id') + 1];
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateChildStarted,
        );
        await gate.future;
        channel.writeStateSync(
          requestId,
          CaptureRequestChannel.stateLockAcquired,
        );
        return _FakeProcess();
      },
      ackTimeout: const Duration(seconds: 2),
    );

    final first = launcherInstance.launch(
      source: CaptureTriggerSource.shortcut,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = await launcherInstance.launch(
      source: CaptureTriggerSource.shortcut,
    );

    expect(spawned, 1);
    expect(second, isA<CaptureLaunchRejected>());
    expect(
      (second as CaptureLaunchRejected).reason,
      CaptureRejectReason.lockBusy,
    );
    gate.complete();
    expect(await first, isA<CaptureLaunchStarted>());
  });
}
