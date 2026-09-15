import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/diagnostics/diagnostic_events.dart';
import 'package:hax_shot/features/diagnostics/diagnostic_log.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('hax_shot_log_test');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on Object {
      // 忽略清理失败。
    }
  });

  test('每次 log 追加一行 JSON，字段包含 time/event/level/pid', () async {
    final log = DiagnosticLogService(directory: directory);
    log.log(
      DiagnosticEvent.shortcutTrigger,
      requestId: '20260915-084211-8f31',
      source: 'shortcut',
    );
    log.log(
      DiagnosticEvent.captureSpawnFailed,
      level: LogLevel.error,
      requestId: '20260915-084211-8f31',
      errorCode: DiagnosticErrorCode.captureProcessSpawnFailed,
      message: '多行\n消息',
    );
    await log.flush();

    final lines = log.logFile.readAsLinesSync();
    expect(lines, hasLength(2));

    final first = jsonDecode(lines[0]) as Map<String, Object?>;
    expect(first['event'], DiagnosticEvent.shortcutTrigger);
    expect(first['request_id'], '20260915-084211-8f31');
    expect(first['source'], 'shortcut');
    expect(first['level'], LogLevel.info);
    expect(first['pid'], isA<int>());
    expect(
      first['time'],
      matches(RegExp(r'\+08:00$|Z$|\+00:00$|-\d{2}:\d{2}$')),
    );

    final second = jsonDecode(lines[1]) as Map<String, Object?>;
    expect(second['level'], LogLevel.error);
    expect(second['error_code'], DiagnosticErrorCode.captureProcessSpawnFailed);
    // 多行 message 必须压成一行，否则 JSON Lines 会被撑坏。
    expect(second['message'], '多行 消息');
  });

  test('超过上限时轮转，并且最多保留 maxFiles 个文件', () async {
    final log = DiagnosticLogService(
      directory: directory,
      maxBytes: 200,
      maxFiles: 3,
    );
    for (var index = 0; index < 40; index++) {
      log.log('event_$index', message: 'x' * 40);
    }
    await log.flush();

    expect(log.logFile.existsSync(), isTrue);
    expect(File('${log.logFile.path}.1').existsSync(), isTrue);
    expect(File('${log.logFile.path}.2').existsSync(), isTrue);
    expect(File('${log.logFile.path}.3').existsSync(), isFalse);
    // 当前文件不会无限增长。
    expect(log.logFile.lengthSync(), lessThanOrEqualTo(log.maxBytes + 400));
  });

  test('logSync 立刻落盘（子进程 SIGKILL 前也能读到）', () {
    final log = DiagnosticLogService(directory: directory);
    log.logSync(
      DiagnosticEvent.captureLockAcquired,
      requestId: 'req-1',
      source: 'shortcut',
    );
    final lines = log.logFile.readAsLinesSync();
    expect(lines, hasLength(1));
    final entry = jsonDecode(lines.single) as Map<String, Object?>;
    expect(entry['event'], DiagnosticEvent.captureLockAcquired);
    expect(entry['request_id'], 'req-1');
  });

  test('不记录截图、AI、Token 等敏感字段', () async {
    final log = DiagnosticLogService(directory: directory);
    log.log(
      DiagnosticEvent.captureReady,
      requestId: 'req-2',
      extra: <String, Object?>{'binding': '<Alt><Shift>z', 'duration_ms': 42},
    );
    await log.flush();
    final raw = log.logFile.readAsStringSync();
    expect(raw.contains('png'), isFalse);
    expect(raw.contains('api_key'), isFalse);
    final entry =
        jsonDecode(log.logFile.readAsLinesSync().single)
            as Map<String, Object?>;
    expect(entry['binding'], '<Alt><Shift>z');
    // 数值字段保留 JSON 原始类型，不敏感的字符串保留原内容。
    expect(entry['duration_ms'], 42);
    // 保留字段不会被 extra 覆盖。
    expect(entry['event'], DiagnosticEvent.captureReady);
  });

  test('敏感 key 的值被脱敏，超长值被截断到 1000 字符', () async {
    final log = DiagnosticLogService(directory: directory);
    log.log(
      DiagnosticEvent.captureReady,
      extra: <String, Object?>{
        'token': 'sk-should-not-appear',
        'ocr': '识别出来的整段文字',
        'screen_text': 'x' * 1500,
        'duration_ms': 42,
      },
    );
    await log.flush();

    final entry =
        jsonDecode(log.logFile.readAsLinesSync().single)
            as Map<String, Object?>;
    expect(entry['token'], '[redacted]');
    expect(entry['ocr'], '[redacted]');
    expect((entry['screen_text']! as String).length, 1000);
    expect(entry['duration_ms'], 42);
    expect(
      log.logFile.readAsStringSync().contains('sk-should-not-appear'),
      isFalse,
    );
  });
}
