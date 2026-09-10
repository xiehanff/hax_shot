import AppKit

/// 决定 `--capture` 的冻结画面浮层落在哪块显示器上。
///
/// 规则必须和 Rust 侧 `rust/src/macos.rs` 的 `target_display()` 保持一致，
/// 否则会出现“浮层在 A 屏、画面是 B 屏”的错位：
///
/// 1. 命令行里的 `--display <id>`（托盘宿主在按下快捷键/菜单的那一瞬间取得）；
/// 2. 光标所在显示器；
/// 3. 主显示器。
enum CaptureDisplay {
  static let argument = "--display"

  /// 从命令行参数读取托盘宿主指定的显示器标识。
  static func requestedDisplayID(arguments: [String]) -> CGDirectDisplayID? {
    guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else {
      return nil
    }
    guard let value = CGDirectDisplayID(arguments[index + 1]), value != 0 else {
      return nil
    }
    return value
  }

  static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return number?.uint32Value
  }

  /// 光标所在显示器。`NSEvent.mouseLocation` 和 `NSScreen.frame` 都在
  /// AppKit 的左下角原点坐标系里，可以直接比较。
  static func screenUnderCursor() -> NSScreen? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
  }

  static func targetScreen(arguments: [String] = ProcessInfo.processInfo.arguments) -> NSScreen? {
    if let requested = requestedDisplayID(arguments: arguments),
      let screen = NSScreen.screens.first(where: { displayID(of: $0) == requested }) {
      return screen
    }
    // 最后兜底到任意一块屏：返回 nil 会让浮层保持默认尺寸、盖不住菜单栏。
    return screenUnderCursor() ?? NSScreen.main ?? NSScreen.screens.first
  }
}
