import Cocoa
import FlutterMacOS

/// 把 `--capture` 进程的窗口从「普通小窗口」升格成铺满目标显示器的冻结画面浮层。
///
/// 捕获进程启动时只是一个带标题栏的普通窗口：抓屏失败（例如还没授予屏幕录制权限）
/// 时，用户看到的是一个小窗口里的引导，而不是盖住菜单栏和 Dock 的全屏黑屏。只有
/// 真正抓到画面之后，Flutter 才调用 `becomeOverlay` 让它铺满整块屏幕。
final class CaptureOverlayWindow {
  static let shared = CaptureOverlayWindow()

  private weak var window: NSWindow?
  private var channel: FlutterMethodChannel?

  private init() {}

  private var escapeMonitor: Any?

  func attach(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    installEscapeMonitor()
    let channel = FlutterMethodChannel(
      name: "hax_shot/capture_window",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "becomeOverlay":
        self?.becomeOverlay()
        result(nil)
      case "exitOverlay":
        self?.exitOverlay()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// 原生兜底的 Esc 退出。
  ///
  /// 捕获进程是覆盖整块屏幕的浮层，一旦 Flutter 侧拿不到键盘焦点（或某个状态
  /// 忘了处理 Esc），用户就会被困住、连菜单栏都点不到。local monitor 直接拿到
  /// 本进程的键盘事件，不依赖 Flutter 的焦点树，任何状态下按 Esc 都能关掉。
  private func installEscapeMonitor() {
    guard escapeMonitor == nil else { return }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53, let window = self?.window else { return event }
      // 只有“铺满屏幕的浮层”需要这里的硬退出；AI 面板等普通窗口交给 Flutter 处理
      // （那边有自己的关闭逻辑，也不会挡住菜单栏）。
      let screenFrame = window.screen?.frame ?? .zero
      let coversScreen =
        window.frame.width >= screenFrame.width
        && window.frame.height >= screenFrame.height
      guard coversScreen else { return event }
      NSLog("hax_shot: escape pressed on full-screen overlay, exiting")
      // 直接结束进程：performClose 对无边框窗口不一定生效，而这是用户唯一的出口，
      // 不能依赖任何一层可能失效的转发。
      exit(0)
    }
  }

  /// 退出浮层状态，回到普通窗口（AI 面板接管同一个窗口之前调用）。
  ///
  /// 必须先把层级和 collectionBehavior 恢复，再让 Dart 去改尺寸：顺序反过来时，
  /// 一旦改尺寸失败，窗口就停在“全屏 + .screenSaver”，用户点不到菜单栏、
  /// Esc 也退不出去，整台机器等于被锁住。
  private func exitOverlay() {
    guard let window else { return }
    window.level = .normal
    window.collectionBehavior = []
    window.isMovableByWindowBackground = false
    window.sharingType = .readOnly
    window.styleMask = [.borderless]
    window.hasShadow = true
  }

  /// 抓到冻结画面之后调用：铺满目标显示器并盖住菜单栏和 Dock。
  ///
  /// 不用 `toggleFullScreen`：原生全屏会切到独立 Space 并播放动画，而冻结画面浮层
  /// 需要立刻盖住菜单栏。窗口此时仍然隐藏，由 Dart 收到成功回调后再 `show()`。
  private func becomeOverlay() {
    guard let window else { return }

    window.styleMask = [.borderless]
    window.level = .screenSaver
    window.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.hasShadow = false
    window.backgroundColor = .black
    // 浮层永远不应该被自己拍进截图。
    window.sharingType = .none

    if let screen = CaptureDisplay.targetScreen() {
      window.setFrame(screen.frame, display: true)
    }
  }
}
