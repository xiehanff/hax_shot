import Cocoa
import FlutterMacOS

let kEventOnTrayIconMouseDown = "onTrayIconMouseDown"
let kEventOnTrayIconMouseUp = "onTrayIconMouseUp"
let kEventOnTrayIconRightMouseDown = "onTrayIconRightMouseDown"
let kEventOnTrayIconRightMouseUp = "onTrayIconRightMouseUp"
let kEventOnTrayMenuItemClick = "onTrayMenuItemClick"

extension NSRect {
    var topLeft: CGPoint {
        set {
            let screenFrameRect = NSScreen.main!.frame
            origin.x = newValue.x
            origin.y = screenFrameRect.height - newValue.y - size.height
        }
        get {
            let screenFrameRect = NSScreen.main!.frame
            return CGPoint(x: origin.x, y: screenFrameRect.height - origin.y - size.height)
        }
    }
}

public class TrayManagerPlugin: NSObject, FlutterPlugin, NSMenuDelegate {
    var channel: FlutterMethodChannel!
    
    var trayIcon: TrayIcon?
    var trayMenu: TrayMenu?
    //    var statusItem: NSStatusItem = NSStatusItem();
    
    var _inited: Bool = false;
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "tray_manager", binaryMessenger: registrar.messenger)
        let instance = TrayManagerPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "destroy":
            destroy(call, result: result)
            break
        case "getBounds":
            getBounds(call, result: result)
            break
        case "setIcon":
            setIcon(call, result: result)
            break
        case "setIconPosition":
            setIconPosition(call, result: result)
            break
        case "setToolTip":
            setToolTip(call, result: result)
            break
        case "setTitle":
            setTitle(call, result: result)
            break
        case "setContextMenu":
            setContextMenu(call, result: result)
            break
        case "popUpContextMenu":
            popUpContextMenu(call, result: result)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    //    private func _init() {
    //        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    //        if let button = statusItem.button {
    //            button.action = #selector(self.statusItemButtonClicked(sender:))
    //            button.target = self
    //            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
    //            _inited = true
    //        }
    //    }
    
    @objc func statusItemButtonClicked(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        var methodName: String?
        
        switch event.type {
        case NSEvent.EventType.leftMouseDown:
            methodName = kEventOnTrayIconMouseDown
            break
        case NSEvent.EventType.leftMouseUp:
            methodName = kEventOnTrayIconMouseUp
            break
        case NSEvent.EventType.rightMouseDown:
            methodName = kEventOnTrayIconRightMouseDown
            break
        case NSEvent.EventType.rightMouseUp:
            methodName = kEventOnTrayIconRightMouseUp
            break
        default:
            break
        }
        if (methodName != nil) {
            channel.invokeMethod(methodName!, arguments: nil, result: nil)
        }
    }
    
    public func destroy(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (trayIcon?.statusItem != nil) {
            NSStatusBar.system.removeStatusItem((trayIcon?.statusItem)!)
        }
        if (trayIcon != nil) {
            trayIcon?.removeImage()
            trayIcon = nil
        }
        result(true)
    }
    
    public func getBounds(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let frame = trayIcon?.statusItem?.button?.window?.frame;
        
        if (frame != nil) {
            let resultData: NSDictionary = [
                "x": frame!.topLeft.x,
                "y": frame!.topLeft.y,
                "width": frame!.size.width,
                "height": frame!.size.height,
            ]
            result(resultData)
        } else {
            result(nil)
        }
    }
    
    public func setIcon(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args:[String: Any] = call.arguments as! [String: Any]
        let base64Icon: String =  args["base64Icon"] as! String;
        let isTemplate: Bool =  args["isTemplate"] as! Bool;
        let iconPosition: String =  args["iconPosition"] as! String;
        let iconSize: Int = args["iconSize"] as! Int;
        
        let imageData = Data(base64Encoded: base64Icon, options: .ignoreUnknownCharacters)
        let image = NSImage(data: imageData!)
        image!.size = NSSize(width: iconSize, height: iconSize)
        image!.isTemplate = isTemplate
        
        if (trayIcon == nil) {
            trayIcon = TrayIcon()
            trayIcon?.onTrayIconMouseDown = { () in
                self.channel.invokeMethod(kEventOnTrayIconMouseDown, arguments: nil, result: nil)
            }
            trayIcon?.onTrayIconMouseUp = { () in
                self.channel.invokeMethod(kEventOnTrayIconMouseUp, arguments: nil, result: nil)
            }
            trayIcon?.onTrayIconRightMouseDown = { () in
                self.channel.invokeMethod(kEventOnTrayIconRightMouseDown, arguments: nil, result: nil)
            }
            trayIcon?.onTrayIconRightMouseUp = { () in
                self.channel.invokeMethod(kEventOnTrayIconRightMouseUp, arguments: nil, result: nil)
            }
        }
        
        trayIcon?.setImage(image!, iconPosition)
        
        result(true)
    }
    
    public func setIconPosition(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args:[String: Any] = call.arguments as! [String: Any]
        let iconPosition: String =  args["iconPosition"] as! String;
        
        trayIcon?.setImagePosition(iconPosition)
        
        result(true)
    }
    
    public func setToolTip(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args:[String: Any] = call.arguments as! [String: Any]
        let toolTip: String =  args["toolTip"] as! String;
        
        trayIcon?.setToolTip(toolTip)
        
        result(true)
    }
    
    public func setTitle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args:[String: Any] = call.arguments as! [String: Any]
        let title: String =  args["title"] as! String;
        
        trayIcon?.setTitle(title)
        
        result(true)
    }
    
    public func setContextMenu(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args:[String: Any] = call.arguments as! [String: Any]
        
        trayMenu = TrayMenu(args["menu"] as! [String: Any])
        trayMenu?.onMenuItemClick = { [weak self] (menuItem: NSMenuItem) in
            guard let strongSelf = self else { return }
            let args: NSDictionary = [
                "id": menuItem.tag,
            ]
            strongSelf.channel.invokeMethod(kEventOnTrayMenuItemClick, arguments: args, result: nil)
        }
        trayMenu?.delegate = self

        // 菜单**常驻**挂在 status item 上，点击由 AppKit 自己处理（见 popUpContextMenu 的注释）。
        trayIcon?.statusItem?.menu = trayMenu

        result(true)
    }

    /// 只把菜单挂上去，**绝不调用 `button.performClick`**。
    ///
    /// 原来的实现是 `statusItem.menu = trayMenu` + `button.performClick(trayIcon)`，而
    /// `TrayIcon` 把 action 注册在 `.leftMouseDown` 上，也就是我们**已经在
    /// `NSControl.mouseDown:` 自己的鼠标跟踪循环里**了。此时 `performClick` 会再开一层
    /// 嵌套的跟踪 + 菜单模态循环，并吃掉真正的 mouseUp —— 外层跟踪永远等不到抬起，
    /// `NSControl.mouseDown:` 不返回，**主线程永久卡死**。
    ///
    /// 实测（sample 采样，HaxShot 宿主跑满 4 天后复现）：主线程 2611/2611 个样本都停在
    /// `NSStatusBarWindow sendEvent → NSControl mouseDown: → _nextEventMatchingEventMask
    /// → CFRunLoopRunSpecific → mach_msg`。主线程一卡，Carbon 全局热键、分布式通知、
    /// MethodChannel 全部收不到，表现就是「按快捷键没反应」，而且看起来完全不像菜单的锅。
    ///
    /// 菜单常驻之后，点击（左右键都算）由 AppKit 负责弹，`onTrayIconMouseDown` 不再回调
    /// Dart；Dart 侧不需要、也不应该再手动弹菜单。
    public func popUpContextMenu(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (trayMenu != nil) {
            trayIcon?.statusItem?.menu = trayMenu
        }
        result(true)
    }

    // NSMenuDelegate

    /// 关掉菜单后**不要**摘掉 `statusItem.menu`：摘掉就回到「点击 → 回调 Dart → Dart 再
    /// 手动弹」那条会把主线程卡死的路。常驻挂着的菜单由 AppKit 正常跟踪，点击菜单项照旧
    /// 通过 `onMenuItemClick` 回给 Dart。
    public func menuDidClose(_ menu: NSMenu) {
    }
}
