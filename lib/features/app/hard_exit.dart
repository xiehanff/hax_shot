import 'dart:io';

/// 立刻结束当前进程。
///
/// 不要用 `dart:io` 的 `exit(0)`：在 macOS 上它会挂在 Flutter 引擎的收尾里，进程
/// 继续活着（实测：窗口、托盘图标都没了，`pgrep -x hax_shot` 还能看到）。捕获进程
/// 每次截图后走的就是这条路径，泄漏的进程会越攒越多。也不能靠 `await
/// windowManager.destroy()`：在 `main()` 早期插件通道还没注册完，这个 Future 永远
/// 不返回。所以直接用 SIGKILL 结束自己，内核会顺手释放单实例锁。
///
/// 调用前必须把所有要落盘的东西写完（例如 `File.writeAsBytes(flush: true)`）：
/// SIGKILL 不给任何收尾机会。
void exitProcessNow() {
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } on Object catch (error) {
    stderr.writeln('结束进程失败：$error');
  }
  // 理论上到不了这里；真到了也不能继续跑下去。
  exit(0);
}
