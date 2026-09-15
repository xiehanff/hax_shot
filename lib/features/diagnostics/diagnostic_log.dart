import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/single_instance_guard.dart';
import 'diagnostic_events.dart';

/// 低频关键事件的持久化日志（JSON Lines）。
///
/// 为什么需要：Release 版从 Finder / LaunchAgent 启动时 `stdout` 落到 launchd，
/// `debugPrint` 谁都看不到；而“按了快捷键没反应”这类问题必须能在用户机器上取到证据。
/// 所以截图触发链上的每个阶段（注册、触发、起进程、子进程 ACK、拿锁）都往这里写一行。
///
/// 刻意做成很小的实现，不引入 logging 包：
/// - 只写生命周期边界 / 状态变化 / 错误，绝不在每帧或鼠标移动时调用；
/// - 单文件超过 [maxBytes] 就轮转，最多保留 [maxFiles] 个文件，不会无限增长；
/// - 只写诊断字段，**不写**截图内容、OCR 文本、AI 对话、屏幕文本、API Key；
/// - 写失败只影响日志本身，永远不向调用方抛异常。
final class DiagnosticLogService {
  DiagnosticLogService({
    Directory? directory,
    this.maxBytes = defaultMaxBytes,
    this.maxFiles = defaultMaxFiles,
  }) : _directory = directory ?? defaultDirectory();

  /// 全进程共用的实例。
  static final instance = DiagnosticLogService();

  /// 日志文件名（轮转后依次是 `hax_shot.log.1` …）。
  static const fileName = 'hax_shot.log';

  /// 单文件上限：2 MB。低频事件下够记很多天。
  static const defaultMaxBytes = 2 * 1024 * 1024;

  /// 含当前文件在内最多保留几个文件。
  static const defaultMaxFiles = 4;

  final int maxBytes;
  final int maxFiles;

  final Directory _directory;

  Directory get directory => _directory;

  File get logFile =>
      File('${_directory.path}${Platform.pathSeparator}$fileName');

  /// 串行化写入，保证同一时刻只有一个 append 在跑（也就保证行不会交错）。
  Future<void> _pending = Future<void>.value();

  /// 平台默认的日志目录：和单实例锁放在同一个 Application Support 目录下。
  static Directory defaultDirectory() {
    final home = Platform.environment['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return Directory(
        '$home/Library/Application Support/'
        '${SingleInstanceGuard.bundleIdentifier}/logs',
      );
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? home;
      return Directory('$localAppData\\hax_shot\\logs');
    }
    final state =
        Platform.environment['XDG_STATE_HOME'] ?? '$home/.local/state';
    return Directory('$state/hax_shot/logs');
  }

  /// 记一条事件。永不抛异常，也永不阻塞调用方。
  ///
  /// [event] / [errorCode] 用 [DiagnosticEvent] / [DiagnosticErrorCode] 里的常量。
  void log(
    String event, {
    String level = LogLevel.info,
    String? requestId,
    String? source,
    String? errorCode,
    String? message,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final entry = <String, Object?>{
      'time': isoTimestamp(DateTime.now()),
      'event': event,
      'level': level,
      'pid': pid,
    };
    if (requestId != null) entry['request_id'] = requestId;
    if (source != null) entry['source'] = source;
    if (errorCode != null) entry['error_code'] = errorCode;
    if (message != null) entry['message'] = _oneLine(message);
    _applyExtra(entry, extra);

    final line = jsonEncode(entry);
    // debug 构建里同时给终端一份，改完即查时不用去翻文件。
    debugPrint('[hax-shot] $line');
    _pending = _pending.then((_) => _append(line)).catchError((Object _) {});
  }

  /// 同步追加（子进程启动早期用：`exitProcessNow()` 是 SIGKILL，异步写会丢）。
  void logSync(
    String event, {
    String level = LogLevel.info,
    String? requestId,
    String? source,
    String? errorCode,
    String? message,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final entry = <String, Object?>{
      'time': isoTimestamp(DateTime.now()),
      'event': event,
      'level': level,
      'pid': pid,
    };
    if (requestId != null) entry['request_id'] = requestId;
    if (source != null) entry['source'] = source;
    if (errorCode != null) entry['error_code'] = errorCode;
    if (message != null) entry['message'] = _oneLine(message);
    _applyExtra(entry, extra);
    try {
      _prepare();
      _rotateIfNeeded();
      logFile.writeAsStringSync(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // 日志不能影响主流程。
    }
  }

  /// 等待已排队的写入落盘（测试和优雅退出用）。
  Future<void> flush() => _pending;

  Future<void> _append(String line) async {
    try {
      _prepare();
      await _rotateIfNeededAsync();
      await logFile.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // 磁盘满 / 权限不对都不该把事件丢掉而影响调用方。
    }
  }

  void _prepare() {
    if (!_directory.existsSync()) {
      _directory.createSync(recursive: true);
    }
  }

  void _rotateIfNeeded() {
    if (!logFile.existsSync()) return;
    if (logFile.lengthSync() <= maxBytes) return;
    _rotateFiles();
  }

  Future<void> _rotateIfNeededAsync() async {
    if (!await logFile.exists()) return;
    if (await logFile.length() <= maxBytes) return;
    _rotateFiles();
  }

  /// 把 `hax_shot.log` → `.1` → `.2` … 依次挪一位，丢掉最老的。
  void _rotateFiles() {
    try {
      final oldest = File('${logFile.path}.${maxFiles - 1}');
      if (oldest.existsSync()) oldest.deleteSync();
      for (var index = maxFiles - 2; index >= 1; index--) {
        final source = File('${logFile.path}.$index');
        if (!source.existsSync()) continue;
        source.renameSync('${logFile.path}.${index + 1}');
      }
      if (logFile.existsSync()) logFile.renameSync('${logFile.path}.1');
    } on Object {
      // 轮转失败时宁可让文件继续变大，也不要丢日志。
    }
  }

  /// 单个字段的长度上限：异常堆栈这类超长值会把一行 JSON 撑到几十 KB。
  static const _maxFieldLength = 1000;

  /// key（转小写后）命中这些片段的字段一律不写原值。
  static const _redactedKeyFragments = <String>[
    'token',
    'secret',
    'password',
    'api_key',
    'apikey',
    'png',
    'image',
    'screenshot',
    'ocr',
    'clipboard',
    'prompt',
  ];

  static const _redactedValue = '[redacted]';

  /// 合并 `extra`：保留字段不可覆盖，敏感 key 的值脱敏，其余值转字符串并截断。
  static void _applyExtra(
    Map<String, Object?> entry,
    Map<String, Object?> extra,
  ) {
    for (final MapEntry<String, Object?> item in extra.entries) {
      if (item.key == 'time' ||
          item.key == 'event' ||
          item.key == 'level' ||
          item.key == 'pid') {
        continue;
      }
      entry[item.key] = _sanitizeExtraValue(item.key, item.value);
    }
  }

  static Object? _sanitizeExtraValue(String key, Object? value) {
    final lowerCaseKey = key.toLowerCase();
    for (final String fragment in _redactedKeyFragments) {
      if (lowerCaseKey.contains(fragment)) return _redactedValue;
    }
    // 数值/布尔/null 保留 JSON 原始类型：诊断时要能直接按数值过滤
    //（例如 duration_ms），全部转字符串会把日志的可计算性丢掉。
    if (value == null || value is num || value is bool) return value;
    return _truncate('$value');
  }

  /// 把多行 message 压成一行，保证 JSON Lines 一行一条。
  static String _oneLine(String value) =>
      _truncate(value.replaceAll('\r', ' ').replaceAll('\n', ' '));

  static String _truncate(String value) => value.length <= _maxFieldLength
      ? value
      : value.substring(0, _maxFieldLength);

  /// ISO8601 + 本地时区偏移（`toIso8601String()` 只有 naive 本地时间）。
  static String isoTimestamp(DateTime time) {
    final offset = time.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final absolute = offset.abs();
    final hours = absolute.inHours.toString().padLeft(2, '0');
    final minutes = (absolute.inMinutes % 60).toString().padLeft(2, '0');
    return '${time.toIso8601String()}$sign$hours:$minutes';
  }
}
