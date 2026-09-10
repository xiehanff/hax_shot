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
      //
      // 用 titled + 全尺寸内容视图而不是 borderless：授权引导和 AI 面板都显示在这个
      // 窗口里，需要系统给的原生圆角（borderless 不会被裁，四角会露出窗口背景）。
      // 抓屏成功后 becomeOverlay() 会把它改成 borderless 并铺满目标显示器。
      CaptureOverlayWindow.applyPanelAppearance(to: self)
      CaptureOverlayWindow.shared.attach(
        messenger: flutterViewController.engine.binaryMessenger,
        window: self
      )
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // nib 加载后 AppKit 会把窗口排到最前，而这时 Flutter 还没画出第一帧，
    // 用户会看到一个小黑窗口闪一下（托盘宿主和捕获进程都这样）。把它设成全透明，
    // 可见性完全交给 Dart：显示前会调用 showWindow() 恢复不透明度。
    alphaValue = 0
  }
}
