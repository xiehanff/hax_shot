import 'dart:io';

/// 保证同一时间只有一份托盘宿主在跑。
///
/// 为什么需要：全局快捷键是**进程内**注册的（macOS 走 Carbon），而系统只保证
/// “同一个 bundle 路径”不会重复启动。用户很容易同时跑两份（例如直接从 DMG 里
/// 运行一份、/Applications 里再一份），两份额外都各自握着快捷键。这时候从其中一份
/// 的托盘菜单点“退出”，另一份还在后台注册着快捷键——用户看到的就是“退出之后按
/// 快捷键照样能截图”，像流氓软件。
///
/// 做法是**操作系统级的文件锁**：锁由内核维护、进程一退出就自动释放，所以不需要
/// 记录 PID、不需要查进程、也不存在 PID 复用误杀的风险。第二份实例拿不到锁就直接
/// 退出（`main()` 里在 `runApp` 之前调用，用户看不到任何窗口）。
///
/// 捕获进程（`--capture`）不参与：它本来就该能同时启动多个。
final class SingleInstanceGuard {
  const SingleInstanceGuard._();

  static const bundleIdentifier = 'com.github.xiehanff.haxShot';

  /// 锁必须一直持有到进程退出：`RandomAccessFile` 关掉锁就没了。
  static RandomAccessFile? _held;

  static File get _lockFile {
    final home = Platform.environment['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return File(
        '$home/Library/Application Support/$bundleIdentifier/hax_shot.lock',
      );
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? home;
      return File('$localAppData\\hax_shot\\hax_shot.lock');
    }
    // Linux：优先用运行时目录（重启即清空），没有就退回缓存目录。
    final runtime =
        Platform.environment['XDG_RUNTIME_DIR'] ?? '$home/.cache/hax_shot';
    return File('$runtime/hax_shot.lock');
  }

  /// 取得独占权，返回 false 表示已经有另一份宿主在跑。
  ///
  /// 检查本身失败（目录建不出来、权限不对……）时返回 true：托盘工具起不来比多跑
  /// 一份更糟，退化行为和以前一样，并在 stderr 留一行原因。
  static bool acquire() {
    if (_held != null) return true;
    try {
      final file = _lockFile;
      file.parent.createSync(recursive: true);
      // append 而不是 write：拿不到锁的那份不应该把持有者的 pid 内容截掉。
      final handle = file.openSync(mode: FileMode.append);
      try {
        // FileLock.exclusive 是非阻塞的：已被占用时直接抛异常，而不是等待。
        handle.lockSync(FileLock.exclusive);
      } on FileSystemException {
        handle.closeSync();
        return false;
      }
      handle.writeStringSync('$pid\n');
      handle.flushSync();
      _held = handle;
      return true;
    } on Object catch (error) {
      stderr.writeln('单实例检查失败（忽略，允许并存）：$error');
      return true;
    }
  }

  /// 正常退出时释放锁。清理失败无所谓：进程结束内核也会释放。
  static void release() {
    final handle = _held;
    _held = null;
    try {
      handle?.closeSync();
      _lockFile.deleteSync();
    } on Object catch (_) {
      // 忽略：锁文件残留不会影响下一次启动（锁本身已经随进程释放）。
    }
  }
}
