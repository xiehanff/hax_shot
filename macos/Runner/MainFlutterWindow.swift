import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 系统生命周期事件 → Dart 的桥。窗口对象自己持有，nib 生命周期结束才释放。
  private var lifecycleBridge: SystemLifecycleBridge?

  /// 全局快捷键桥（Carbon）。只有托盘宿主需要它。
  private var shortcutBridge: ShortcutBridge?

  /// borderless 窗口默认 `canBecomeKey == false`，那就完全收不到键盘事件：
  /// 浮层里的文字标注打不了字，AI 面板里的 API Key 也粘贴不了（⌘V 没反应）。
  override var canBecomeKey: Bool { true }

  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let isCaptureProcess = ProcessInfo.processInfo.arguments.contains("--capture")

    if isCaptureProcess {
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

    // 托盘宿主是 LSUIElement 隐藏窗口应用：屏幕锁定 / 睡眠唤醒时不一定收到
    // applicationDidBecomeActive，Flutter 的 AppLifecycleState 覆盖不到这些事件。
    // 这里把原生事件转给 Dart（lib/features/diagnostics/app_lifecycle_bridge.dart），
    // 由 Dart 的 ShortcutService 决定怎么重新注册全局快捷键——快捷键逻辑不搬到 Swift。
    //
    // 两个桥都只给托盘宿主用：`--capture` 进程是短命的，既不注册全局快捷键、
    // 也没有需要恢复的生命周期状态。
    if !isCaptureProcess {
      lifecycleBridge = SystemLifecycleBridge(
        messenger: flutterViewController.engine.binaryMessenger
      )
      shortcutBridge = ShortcutBridge(
        messenger: flutterViewController.engine.binaryMessenger
      )
    }

    // nib 加载后 AppKit 会把窗口排到最前，而这时 Flutter 还没画出第一帧，
    // 用户会看到一个小黑窗口闪一下（托盘宿主和捕获进程都这样）。把它设成全透明，
    // 可见性完全交给 Dart：显示前会调用 showWindow() 恢复不透明度。
    alphaValue = 0
  }
}

/// 最小生命周期桥：只把 `macos_wake` / `macos_unlock` / `macos_session_active` 发给 Dart。
///
/// 不在这里做任何快捷键注册/注销：Carbon 热键的状态统一由 Dart 的
/// `MacosShortcutService` 管，否则会出现两处各自维护注册状态。
final class SystemLifecycleBridge {
  private let channel: FlutterMethodChannel
  private var workspaceObservers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "hax_shot/lifecycle",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      // Dart 只监听事件，不主动调用；明确拒绝而不是静默。
      result(FlutterMethodNotImplemented)
    }

    let workspace = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      workspace.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.emit("macos_wake") }
    )
    workspaceObservers.append(
      workspace.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.emit("macos_wake") }
    )
    workspaceObservers.append(
      workspace.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
        queue: .main
      ) { [weak self] _ in self?.emit("macos_session_active") }
    )

    // 锁屏/解锁只有 DistributedNotificationCenter 的私有通知可用：
    // 这两个名字 Apple 没写进文档，但它们是 Mac 上获取锁屏状态的事实标准。
    let distributed = DistributedNotificationCenter.default()
    distributedObservers.append(
      distributed.addObserver(
        forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil,
        queue: .main
      ) { [weak self] _ in self?.emit("macos_unlock") }
    )
  }

  deinit {
    let workspace = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers {
      workspace.removeObserver(observer)
    }
    let distributed = DistributedNotificationCenter.default()
    for observer in distributedObservers {
      distributed.removeObserver(observer)
    }
  }

  private func emit(_ event: String) {
    channel.invokeMethod("lifecycle", arguments: event)
  }
}
