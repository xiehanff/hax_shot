import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// borderless 窗口默认 `canBecomeKey == false`，那就完全收不到键盘事件：
  /// 浮层里的文字标注打不了字，AI 面板里的 API Key 也粘贴不了（⌘V 没反应）。
  override var canBecomeKey: Bool { true }

  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    if ProcessInfo.processInfo.arguments.contains("--capture") {
      // 捕获进程启动时是一个小的无边框窗口：抓屏失败（没授权、ScreenCast 出错……）
      // 时 Flutter 在这个小窗口里显示引导和错误，用户不会被全屏浮层困住；只有
      // 抓屏成功后 Flutter 才会调用 CaptureOverlayWindow.becomeOverlay() 把它铺满
      // 目标显示器。
      //
      // 不要原生标题栏按钮：窗口的视觉和交互都由 Flutter 负责（macOS 的红黄绿会压在
      // 我们自己的关闭按钮上）。不要在这里设 level，也不要 titleBarStyle：
      // window_manager 的 setTitleBarStyle 会在没有标题栏按钮的窗口上强解包 nil 崩溃，
      // 所以 lib/main.dart 只在 macOS 捕获模式之外传该选项。
      styleMask = [.borderless]
      isMovableByWindowBackground = false
      hasShadow = true
      CaptureOverlayWindow.shared.attach(
        messenger: flutterViewController.engine.binaryMessenger,
        window: self
      )
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
