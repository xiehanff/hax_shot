import 'dart:convert';
import 'dart:io';

import '../app/single_instance_guard.dart';

/// Capture 请求的 ACK 通道：Host 建请求文件，子进程按阶段覆盖 `state`。
///
/// 为什么用临时状态文件而不是 socket/IPC：`--capture` 子进程是 detached 启动的，
/// 宿主不需要和它保持连接，只需要确认“它真的进了截图启动链”。一个 requestId 对应
/// 一个小 JSON 文件就够，进程崩溃也不会留下悬空连接。
///
/// 状态流转（见 docs/development-guide.md）：
/// `created → child_started → lock_acquired → capture_ready`，失败分支是
/// `lock_busy` / `startup_failed`。宿主只等到 `lock_acquired` 就够，不等用户画完选框。
final class CaptureRequestChannel {
  CaptureRequestChannel({Directory? directory})
    : _directory = directory ?? defaultDirectory();

  static final instance = CaptureRequestChannel();

  static const directoryName = 'capture_requests';

  /// 超过这个时长的请求文件视为诊断残留（下次启动清掉）。
  static const staleAfter = Duration(hours: 24);

  static const stateCreated = 'created';
  static const stateChildStarted = 'child_started';
  static const stateLockAcquired = 'lock_acquired';
  static const stateLockBusy = 'lock_busy';
  static const stateStartupFailed = 'startup_failed';
  static const stateCaptureReady = 'capture_ready';
  static const stateFinished = 'finished';

  final Directory _directory;

  Directory get directory => _directory;

  static Directory defaultDirectory() {
    final home = Platform.environment['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return Directory(
        '$home/Library/Application Support/'
        '${SingleInstanceGuard.bundleIdentifier}/$directoryName',
      );
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? home;
      return Directory('$localAppData\\hax_shot\\$directoryName');
    }
    final runtime =
        Platform.environment['XDG_RUNTIME_DIR'] ?? '$home/.cache/hax_shot';
    return Directory('$runtime/$directoryName');
  }

  File fileFor(String requestId) =>
      File('${_directory.path}${Platform.pathSeparator}$requestId.json');

  /// 异步写状态（宿主进程用）。失败不影响截图本身。
  ///
  /// 写入是「先写 .tmp 再 rename」：宿主在轮询 `state`，原地覆盖会被读到半写的 JSON。
  Future<void> writeState(
    String requestId,
    String state, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    try {
      _prepare();
      final payload = _readSync(requestId) ?? <String, Object?>{};
      _applyState(payload, requestId, state, extra);
      final file = fileFor(requestId);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(file.path);
    } on Object {
      // ACK 通道失败只是少一条诊断，不该影响截图流程。
    }
  }

  /// 同步写状态：子进程在 `exitProcessNow()`（SIGKILL）前必须落盘。
  void writeStateSync(
    String requestId,
    String state, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    try {
      _prepare();
      final payload = _readSync(requestId) ?? <String, Object?>{};
      _applyState(payload, requestId, state, extra);
      final file = fileFor(requestId);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(payload), flush: true);
      temporary.renameSync(file.path);
    } on Object {
      // 同上。
    }
  }

  Map<String, Object?>? readState(String requestId) => _readSync(requestId);

  /// 读出文件里的 `state` 字段；文件不存在或还没写 state 时返回 null。
  String? readStateName(String requestId) {
    final payload = _readSync(requestId);
    final state = payload?['state'];
    return state is String ? state : null;
  }

  /// 删掉一个请求文件。超过 [maxAge] 才删；[cutoff] 由 [cleanupExpired] 传进来，
  /// 避免每个文件都算一次时间。
  void delete(
    String requestId, {
    Duration maxAge = staleAfter,
    DateTime? cutoff,
  }) {
    try {
      final file = fileFor(requestId);
      if (!file.existsSync()) return;
      final deadline = cutoff ?? DateTime.now().subtract(maxAge);
      if (file.statSync().modified.isAfter(deadline)) return;
      file.deleteSync();
    } on Object {
      // 删不掉就留着，下次清理会处理。
    }
  }

  /// 清理过期请求文件；正在执行的请求（刚刚写过）不会被删。
  ///
  /// 宿主启动时清一次，之后每次截图结束后再清一次：宿主可能连续运行几天，
  /// 只在启动时清的话 `capture_requests/` 会一直涨。
  void cleanupExpired({Duration maxAge = staleAfter}) {
    try {
      if (!_directory.existsSync()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      for (final entity in _directory.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.json') || name.endsWith('.json.tmp')) {
          // 保留一个原子写的残留 `.tmp` 也无妨，但它不算请求文件。
          continue;
        }
        delete(
          name.substring(0, name.length - '.json'.length),
          maxAge: maxAge,
          cutoff: cutoff,
        );
      }
    } on Object {
      // 目录不可读就跳过清理。
    }
  }

  void _prepare() {
    if (!_directory.existsSync()) {
      _directory.createSync(recursive: true);
    }
  }

  Map<String, Object?>? _readSync(String requestId) {
    try {
      final file = fileFor(requestId);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      // 写了一半 / 被外部改坏：当作没有历史状态，直接覆盖。
      return null;
    }
  }

  void _applyState(
    Map<String, Object?> payload,
    String requestId,
    String state,
    Map<String, Object?> extra,
  ) {
    final now = DateTime.now().toIso8601String();
    payload
      ..['request_id'] = requestId
      ..['state'] = state
      ..['updated_at'] = now
      ..['pid'] = pid;
    payload.putIfAbsent('created_at', () => now);
    payload.addAll(extra);
  }
}
