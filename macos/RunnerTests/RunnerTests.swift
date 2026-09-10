import Cocoa
import FlutterMacOS
import XCTest

@testable import hax_shot

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  /// 授权引导和 AI 面板都显示在捕获进程的窗口里。那个窗口原来是 borderless：
  /// macOS 不会给 borderless 窗口做圆角裁剪，四角外侧露出的是窗口自己的背景色，
  /// 用户看到的就是“有圆角但不透”。这里断言它用的是和托盘宿主（设置页/欢迎页）
  /// 一样的 titled + 全尺寸内容视图配置，靠系统做原生圆角。
  func testPanelAppearanceUsesNativeRoundedWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    CaptureOverlayWindow.applyPanelAppearance(to: window)
    XCTAssertTrue(window.styleMask.contains(.titled), "必须有标题栏系统才会裁圆角")
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "内容要铺满整个窗口")
    // 注意：`.borderless` 的值是 0，`styleMask.contains(.borderless)` 永远为 true，
    // 不能用它判断。窗口是不是 titled 看 `.titled` 就够了。
    XCTAssertFalse(window.styleMask.contains(.resizable), "不要可调整大小（AI 面板是固定尺寸）")
    XCTAssertEqual(window.titleVisibility, .hidden, "不要显示标题")
    XCTAssertTrue(window.titlebarAppearsTransparent, "标题栏要透明")
    // 有原生圆角裁剪，圆角外不会有窗口背景露出来，所以背景必须不透明（否则
    // 会和窗口阴影叠出脏边）。
    XCTAssertTrue(window.isOpaque)
    // 没有 .closable/.miniaturizable/.resizable 时这三个按钮根本不存在（nil），
    // 也就是不会出现 macOS 的红黄绿——关闭按钮由 Flutter 自己画在右上角。
    XCTAssertNil(window.standardWindowButton(.closeButton))
    XCTAssertNil(window.standardWindowButton(.miniaturizeButton))
    XCTAssertNil(window.standardWindowButton(.zoomButton))
  }
}
