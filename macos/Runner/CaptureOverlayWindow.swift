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

  /// 把窗口调成和托盘宿主（设置页 / 欢迎页）一样的“面板窗口”外观。
  ///
  /// macOS 只对 titled 窗口做原生圆角裁剪：borderless 窗口不会被裁，四角外侧露出的
  /// 是窗口自己的背景色，看起来就是“有圆角但不透”。titled + 全尺寸内容视图 + 透明
  /// 隐藏标题栏既拿到原生圆角（角外直接是桌面），又保持无标题栏的观感——容器边界和
  /// 阴影都交给系统。
  ///
  /// 捕获浮层自己（becomeOverlay）必须是 borderless：它要铺满屏幕、盖住菜单栏和 Dock。
  static func applyPanelAppearance(to window: NSWindow) {
    window.styleMask = [.titled, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) {
      window.titlebarSeparatorStyle = .none
    }
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    // 有原生圆角裁剪，圆角外侧不会露出窗口背景，这里只需要一个不透明的深色兜底。
    // 底色等同 Dart 侧 `HaxAiColors.scaffoldBg`（lib/features/ai/views/widgets/ai_colors.dart，0xFF121318）。
    window.isOpaque = true
    window.backgroundColor = NSColor(
      srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x18 / 255, alpha: 1)
    window.isMovable = true
    window.isMovableByWindowBackground = false
    window.hasShadow = true
  }

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
      // 用 _exit 而不是 exit：exit 会跑 Flutter 引擎注册的 atexit 收尾，实测在
      // macOS 上会挂住，进程残留在后台。
      _exit(0)
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
    // AI 面板接管同一个窗口：回到原生圆角的面板外观（见 applyPanelAppearance）。
    Self.applyPanelAppearance(to: window)
  }

  /// 抓到冻结画面之后调用：铺满目标显示器并盖住菜单栏和 Dock。
  ///
  /// 不用 `toggleFullScreen`：原生全屏会切到独立 Space 并播放动画，而冻结画面浮层
  /// 需要立刻盖住菜单栏。窗口此时仍然隐藏，由 Dart 收到成功回调后再 `show()`。
  private func becomeOverlay() {
    guard let window else { return }

    // 启动时窗口是全透明的（见 MainFlutterWindow），铺满屏幕时恢复。
    window.alphaValue = 1
    // 全屏浮层要铺满屏幕、必须是直角：不透明 + 纯黑背景。
    window.isOpaque = true
    window.backgroundColor = .black
    window.styleMask = [.borderless]
    window.level = .screenSaver
    window.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.hasShadow = false
    // 浮层永远不应该被自己拍进截图。
    window.sharingType = .none

    if let screen = CaptureDisplay.targetScreen() {
      window.setFrame(screen.frame, display: true)
    }
  }
}
