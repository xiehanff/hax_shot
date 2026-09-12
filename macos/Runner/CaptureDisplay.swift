import AppKit

/// 决定 `--capture` 的冻结画面浮层落在哪块显示器上。
///
/// 选屏规则（`--display <id>` → 光标所在显示器 → 主显示器）由 Rust 独占实现
/// （`rust/src/macos.rs` 的 `resolve_target_display`），这里通过 `hax_shot_target_display`
/// 拿到 `CGDirectDisplayID`，只负责把它映射到 `NSScreen`。
/// 两边共用一份规则，才不会出现“浮层在 A 屏、画面是 B 屏”的错位。
enum CaptureDisplay {
  static let argument = "--display"

  /// Rust 原生层里的选屏函数签名：`u32 requested -> u32 displayID`。
  private typealias TargetDisplayFunction = @convention(c) (UInt32) -> UInt32

  /// 惰性加载原生选屏函数；dylib 或符号缺失时为 nil。
  ///
  /// dylib 随 App 打包在 `Contents/Frameworks/`，主程序带 `LC_RPATH
  /// @executable_path/../Frameworks`，所以先按 rpath 试，再退回绝对路径。
  private static let targetDisplayFunction: TargetDisplayFunction? = {
    let candidates = [
      "@rpath/libhax_shot_native.dylib",
      Bundle.main.privateFrameworksPath.map { "\($0)/libhax_shot_native.dylib" },
    ].compactMap { $0 }

    for path in candidates {
      guard let handle = dlopen(path, RTLD_NOW) else { continue }
      guard let symbol = dlsym(handle, "hax_shot_target_display") else { continue }
      return unsafeBitCast(symbol, to: TargetDisplayFunction.self)
    }
    return nil
  }()

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

  static func targetScreen(arguments: [String] = ProcessInfo.processInfo.arguments) -> NSScreen? {
    let requested = requestedDisplayID(arguments: arguments) ?? 0

    guard let targetDisplay = targetDisplayFunction else {
      // 理论上不会发生：抓屏本身也依赖同一个 dylib。
      NSLog("CaptureDisplay: 无法加载 hax_shot_target_display，浮层回退到主显示器")
      return NSScreen.main ?? NSScreen.screens.first
    }

    let targetID = targetDisplay(requested)
    if let screen = NSScreen.screens.first(where: { displayID(of: $0) == targetID }) {
      return screen
    }

    // Rust 给出了 id，但 AppKit 认不出来（屏幕配置正在变化）。
    // 最后兜底到任意一块屏：返回 nil 会让浮层保持默认尺寸、盖不住菜单栏。
    NSLog("CaptureDisplay: Rust 返回的显示器 \(targetID) 不在 NSScreen.screens 里，回退到主显示器")
    return NSScreen.main ?? NSScreen.screens.first
  }
}
