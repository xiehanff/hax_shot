import 'dart:io';

/// 保证同一时间只有一份托盘宿主、一个全屏捕获流程在跑。
///
/// 为什么需要：全局快捷键是**进程内**注册的（macOS 走 Carbon），而系统只保证
/// “同一个 bundle 路径”不会重复启动。用户很容易同时跑两份（例如直接从 DMG 里
/// 运行一份、/Applications 里再一份），两份额外都各自握着快捷键。这时候从其中一份
/// 的托盘菜单点“退出”，另一份还在后台注册着快捷键——用户看到的就是“退出之后按
/// 快捷键照样能截图”，像流氓软件。
///
/// 做法是**操作系统级的文件锁**：锁由内核维护、进程一退出就自动释放，所以不需要
/// 记录 PID、不需要查进程、也不存在 PID 复用误杀的风险。锁文件本身永久保留——删它
/// 反而会引入竞态（见 `release()` 的注释）。第二份实例拿不到锁就直接退出（`main()`
/// 里在 `runApp` 之前调用，用户看不到任何窗口）。
///
/// 捕获进程使用另一把锁：重复触发可以启动多个 OS 进程，但只有一个能进入截图浮层，
/// 避免多层 `.screenSaver` 窗口叠住桌面、让 Esc 看起来失效。
final class SingleInstanceGuard {
  const SingleInstanceGuard._();

  static const bundleIdentifier = 'com.github.xiehanff.haxShot';
  static const captureHandoffArgument = '--capture-handoff';

  /// 锁必须一直持有到进程退出：`RandomAccessFile` 关掉锁就没了。
  static RandomAccessFile? _held;
  static RandomAccessFile? _captureHeld;
  static RandomAccessFile? _captureHandoffHeld;

  static File get _hostLockFile => _lockFile('hax_shot.lock');

  static File get _captureLockFile => _lockFile('hax_shot_capture.lock');

  static File get _captureHandoffLockFile =>
      _lockFile('hax_shot_capture_handoff.lock');

  static File _captureHandoffReadyFile(String token) =>
      _lockFile('hax_shot_capture_handoff_$token.ready');

  static File _lockFile(String name) {
    final home = Platform.environment['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return File('$home/Library/Application Support/$bundleIdentifier/$name');
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? home;
      return File('$localAppData\\hax_shot\\$name');
    }
    // Linux：优先用运行时目录（重启即清空），没有就退回缓存目录。
    final runtime =
        Platform.environment['XDG_RUNTIME_DIR'] ?? '$home/.cache/hax_shot';
    return File('$runtime/$name');
  }

  /// 取得独占权，返回 false 表示已经有另一份宿主在跑。
  ///
  /// 检查本身失败（目录建不出来、权限不对……）时返回 true：托盘工具起不来比多跑
  /// 一份更糟，退化行为和以前一样，并在 stderr 留一行原因。
  static bool acquire() {
    if (_held != null) return true;
    final result = _tryAcquire(_hostLockFile, '托盘宿主', failOpen: true);
    _held = result.handle;
    return result.acquired;
  }

  /// 抓屏进程取得全屏捕获独占权；拿不到时应在显示窗口前立刻退出。
  /// 捕获锁失败必须 fail-close：少截一次也不能冒险叠出多个 `.screenSaver` 浮层。
  static bool acquireCapture() {
    if (_captureHeld != null) return true;
    // 授权接替者已预约时，普通快捷键进程不能参与捕获锁竞争。
    if (_isCaptureHandoffReserved()) return false;
    return _acquireCaptureLock();
  }

  /// 启动授权接替者前清掉同 token 的旧确认文件，避免误认一次历史交接。
  static void prepareCaptureHandoff(String token) {
    final readyFile = _captureHandoffReadyFile(token);
    if (readyFile.existsSync()) readyFile.deleteSync();
  }

  /// 旧进程等待接替者取得预约锁并写出确认，再安全退出释放捕获锁。
  static Future<bool> waitForCaptureHandoff(String token) async {
    final readyFile = _captureHandoffReadyFile(token);
    for (var attempt = 0; attempt < 40; attempt++) {
      if (readyFile.existsSync()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  static void cancelCaptureHandoff(String token) {
    final readyFile = _captureHandoffReadyFile(token);
    try {
      if (readyFile.existsSync()) readyFile.deleteSync();
    } on Object {
      // 接替进程退出时也会清理；这里失败不能遮住原始启动错误。
    }
  }

  /// 授权接替者先独占预约锁并通知旧进程，再等待旧进程退出释放捕获锁。
  /// 预约期间普通快捷键进程会被 [acquireCapture] 拒绝，不能抢先。
  static Future<bool> acquireCaptureAfterHandoff(String token) async {
    final reservation = _tryAcquire(
      _captureHandoffLockFile,
      '抓屏交接',
      failOpen: false,
    );
    if (!reservation.acquired || reservation.handle == null) return false;
    _captureHandoffHeld = reservation.handle;
    final readyFile = _captureHandoffReadyFile(token);
    try {
      readyFile.writeAsStringSync('$pid\n', flush: true);
      for (var attempt = 0; attempt < 40; attempt++) {
        if (_acquireCaptureLock()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return false;
    } on Object catch (error) {
      stderr.writeln('抓屏交接失败（拒绝启动）：$error');
      return false;
    } finally {
      cancelCaptureHandoff(token);
      final handle = _captureHandoffHeld;
      _captureHandoffHeld = null;
      _close(handle);
    }
  }

  static bool _acquireCaptureLock() {
    if (_captureHeld != null) return true;
    final result = _tryAcquire(_captureLockFile, '抓屏进程', failOpen: false);
    _captureHeld = result.handle;
    return result.acquired;
  }

  static bool _isCaptureHandoffReserved() {
    final result = _tryAcquire(
      _captureHandoffLockFile,
      '抓屏交接检查',
      failOpen: false,
    );
    if (!result.acquired || result.handle == null) return true;
    _close(result.handle);
    return false;
  }

  static ({bool acquired, RandomAccessFile? handle}) _tryAcquire(
    File file,
    String label, {
    required bool failOpen,
  }) {
    try {
      file.parent.createSync(recursive: true);
      // append 而不是 write：拿不到锁的那份不应该把持有者的 pid 内容截掉。
      final handle = file.openSync(mode: FileMode.append);
      try {
        // FileLock.exclusive 是非阻塞的：已被占用时直接抛异常，而不是等待。
        handle.lockSync(FileLock.exclusive);
      } on FileSystemException {
        handle.closeSync();
        return (acquired: false, handle: null);
      }
      // 拿到锁之后才能截断：锁文件是永久存在的（release 不删除），截断保证
      // 里面只留当前持有者的 pid，而不是历次启动的累加。
      handle.truncateSync(0);
      handle.writeStringSync('$pid\n');
      handle.flushSync();
      return (acquired: true, handle: handle);
    } on Object catch (error) {
      final action = failOpen ? '允许启动' : '拒绝启动';
      stderr.writeln('$label 单实例检查失败（$action）：$error');
      return (acquired: failOpen, handle: null);
    }
  }

  /// 正常退出时释放锁。
  ///
  /// **不删除锁文件**：删了会开一个真实的竞态——A 关掉 fd（锁被内核释放）到 A 删掉
  /// 路径之间存在窗口，B 可能正好打开这个旧 inode 拿到锁，随后 A 的删除让 C 新建一个
  /// 同名文件也能拿到锁，于是 B、C 同时认为自己是唯一实例。锁文件永久存在时，这份
  /// 竞态根本不存在：`flock`/`FileLock` 绑在 inode 上，进程退出内核就释放。
  static void release() {
    final handle = _held;
    _held = null;
    _close(handle);
  }

  /// 捕获浮层变成普通 AI 面板时主动释放；其它退出由内核回收。
  static void releaseCapture() {
    final handle = _captureHeld;
    _captureHeld = null;
    _close(handle);
  }

  static void _close(RandomAccessFile? handle) {
    try {
      handle?.closeSync();
    } on Object catch (_) {
      // 忽略：进程结束内核也会释放锁。
    }
  }
}
