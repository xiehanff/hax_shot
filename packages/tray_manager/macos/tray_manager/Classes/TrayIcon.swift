//
//  TrayIcon.swift
//  tray_manager
//
//  Created by Lijy91 on 2022/5/15.
//

import AppKit

public class TrayIcon: NSView {
    public var onTrayIconMouseDown: (() -> Void)?
    public var onTrayIconMouseUp: (() -> Void)?
    public var onTrayIconRightMouseDown: (() -> Void)?
    public var onTrayIconRightMouseUp: (() -> Void)?

    var statusItem: NSStatusItem?

    public init() {
        super.init(frame: NSRect.zero)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Do not add an empty NSView over the button: on current macOS versions
            // that hides button.image. Handle events on the native status button so
            // the image remains visible and click behavior is preserved.
            button.target = self
            button.action = #selector(statusItemButtonClicked(_:))
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setImage(_ image: NSImage, _ imagePosition: String) {
        if let button = statusItem?.button {
            button.image = image
            setImagePosition(imagePosition)
        }
    }

    public func setImagePosition(_ imagePosition: String) {
        if let button = statusItem?.button {
            button.imagePosition = imagePosition == "right"
                ? NSControl.ImagePosition.imageRight
                : NSControl.ImagePosition.imageLeft
        }
    }

    @objc private func statusItemButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown:
            onTrayIconMouseDown?()
        case .leftMouseUp:
            onTrayIconMouseUp?()
        case .rightMouseDown:
            onTrayIconRightMouseDown?()
        case .rightMouseUp:
            onTrayIconRightMouseUp?()
        default:
            break
        }
    }

    public func removeImage() {
        statusItem?.button?.image = nil
    }

    public func setTitle(_ title: String) {
        statusItem?.button?.title = title
    }

    public func setToolTip(_ toolTip: String) {
        statusItem?.button?.toolTip = toolTip
    }
}
