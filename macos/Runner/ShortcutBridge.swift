import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// 极薄的 macOS 全局快捷键桥：直接调 Carbon，并把真实 OSStatus 返回给 Dart。
///
/// 为什么不用 `hotkey_manager_macos`：它的 Swift 端在 `register()` 里**无条件**
/// `result(true)`，而 soffes/HotKey 内部的 `RegisterEventHotKey` 失败时是静默 `return`。
/// 于是「Carbon 没注册上」和「注册成功」在 Dart 侧长得一模一样——设置页显示“已启用”，
/// 用户按下去却毫无反应，正是我们要消灭的那种故障。
///
/// 这里只做三件事，不含任何快捷键业务逻辑（注册状态机、改绑事务、回滚都在 Dart 的
/// `MacosShortcutService` 里）：
///
/// 1. `register({keyCode, modifiers})` → 真实 `RegisterEventHotKey` 的 OSStatus；
/// 2. `unregister()` → 真实 `UnregisterEventHotKey` 的 OSStatus；
/// 3. 按键触发时通过 `triggered` 回调 Dart。
///
/// keyCode 的约定必须和以前一致：**Carbon 虚拟键码（kVK_*）**，不是 USB HID usage。
/// 以前 `hotkey_manager` 也是把 Carbon 键码发过来的（它内部用 Flutter 的
/// `kMacOsToPhysicalKey` 做映射），所以 Dart 侧沿用同一份映射即可，行为不变。
final class ShortcutBridge {
  private let channel: FlutterMethodChannel

  /// Carbon 注册出来的热键引用；非空表示当前确实注册着。
  private var hotKeyRef: EventHotKeyRef?

  /// `kEventHotKeyPressed` 的事件处理器引用。
  private var eventHandlerRef: EventHandlerRef?

  /// HotKeyID 的签名，随便取一个四字符码，只用于区分本进程的热键。
  private static let signature: OSType = 0x4853_4854  // 'HSHT'

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "hax_shot/shortcut",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        self?.register(call, result: result)
      case "unregister":
        self?.unregister(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    unregisterInternal()
  }

  // MARK: - MethodChannel

  private func register(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    guard let keyCode = arguments["keyCode"] as? Int, keyCode > 0 else {
      result([
        "ok": false,
        "osStatus": Int(paramErr),
        "message": "缺少合法的 keyCode（Carbon 虚拟键码）",
      ])
      return
    }
    let modifiers = carbonModifiers(from: arguments["modifiers"] as? [String] ?? [])

    // 先清掉上一个：Carbon 对同一组合重复注册会返回 eventHotKeyExistsErr，
    // 让 Dart 侧的改绑事务自己决定失败/回滚，这里不留旧注册。
    unregisterInternal()

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installStatus = InstallEventHandler(
      // 必须是 GetEventDispatcherTarget()，不能是 GetApplicationEventTarget()。
      // 后者是 Carbon 自己那套 RunApplicationEventLoop 的目标，在 Flutter 这种
      // `NSApplication` 事件循环里注册会返回 noErr，但 hot key 事件永远送不到处理器
      //（实测：注册 status=0，按下去 handler 一次都不进）。soffes/HotKey 用的也是
      // GetEventDispatcherTarget()，这里跟它保持一致。
      GetEventDispatcherTarget(),
      haxShotShortcutEventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )
    guard installStatus == noErr else {
      eventHandlerRef = nil
      result(["ok": false, "osStatus": Int(installStatus), "message": "安装热键事件处理器失败"])
      return
    }

    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      modifiers,
      hotKeyID,
      // 同上：注册目标和 InstallEventHandler 必须是同一个 dispatcher target。
      GetEventDispatcherTarget(),
      0,
      &reference
    )
    guard status == noErr, reference != nil else {
      // 注册失败就把处理器也摘掉，避免留下一个永远不触发的空壳。
      removeEventHandler()
      result([
        "ok": false,
        "osStatus": Int(status),
        "message": Self.describe(status),
      ])
      return
    }
    hotKeyRef = reference
    result(["ok": true, "osStatus": 0])
  }

  private func unregister(result: @escaping FlutterResult) {
    if let reference = hotKeyRef {
      let status = UnregisterEventHotKey(reference)
      guard status == noErr else {
        // 保留 hotKeyRef：注销没成功时它可能还活着，Dart 侧需要据此重试而不是
        // 假装已经清干净（否则会出现两个 handler 一起触发截图）。
        result([
          "ok": false,
          "osStatus": Int(status),
          "message": Self.describe(status),
        ])
        return
      }
      hotKeyRef = nil
    }
    removeEventHandler()
    result(["ok": true, "osStatus": 0])
  }

  // MARK: - Carbon

  /// 按键触发：Carbon 的事件处理器跑在主线程的事件循环上，这里再兜一层。
  fileprivate func fire() {
    if Thread.isMainThread {
      channel.invokeMethod("triggered", arguments: nil)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod("triggered", arguments: nil)
      }
    }
  }

  private func removeEventHandler() {
    guard let reference = eventHandlerRef else { return }
    RemoveEventHandler(reference)
    eventHandlerRef = nil
  }

  private func unregisterInternal() {
    if let reference = hotKeyRef {
      UnregisterEventHotKey(reference)
      hotKeyRef = nil
    }
    removeEventHandler()
  }

  /// `register` 的 modifiers 字符串 → Carbon 修饰键掩码。
  ///
  /// 注意 Carbon 用的是 `cmdKey` / `shiftKey` / `optionKey` / `controlKey`，
  /// 不是 `NSEvent.ModifierFlags`（两者位值不同，混用会注册出错误的组合）。
  private func carbonModifiers(from names: [String]) -> UInt32 {
    var modifiers: UInt32 = 0
    for name in names {
      switch name.lowercased() {
      case "alt", "option":
        modifiers |= UInt32(optionKey)
      case "control", "ctrl":
        modifiers |= UInt32(controlKey)
      case "shift":
        modifiers |= UInt32(shiftKey)
      case "meta", "super", "command", "cmd":
        modifiers |= UInt32(cmdKey)
      default:
        break
      }
    }
    return modifiers
  }

  /// 把常见 OSStatus 翻成能直接给用户看的话。message 会进诊断日志。
  private static func describe(_ status: OSStatus) -> String {
    switch status {
    case OSStatus(eventHotKeyExistsErr):
      return "这个组合已经被占用（系统保留，或本进程已注册）"
    case OSStatus(paramErr):
      return "参数不合法（键码或修饰键不被 Carbon 接受）"
    default:
      return "Carbon 返回 OSStatus \(status)"
    }
  }
}

/// Carbon 需要 C 函数指针，不能带捕获，所以放在文件级。
private func haxShotShortcutEventHandler(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let bridge = Unmanaged<ShortcutBridge>.fromOpaque(userData).takeUnretainedValue()
  bridge.fire()
  return noErr
}
