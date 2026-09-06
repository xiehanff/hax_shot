# Screenshot 源码阅读报告

## 0. 阅读范围

- 仓库：<https://github.com/tyypgzl/screenshot>
- 本地路径：`/home/han/Documents/github/hax_shot/references/screenshot`
- 本地浅克隆提交：`36eb70a`
- 技术：Swift + AppKit + ScreenCaptureKit
- 目标：研究最小菜单栏截图工具的实际主链路。

这是三个参考项目中最接近“轻量截图 MVP”的一个。它的 README 声称 MIT，但本地仓库没有 `LICENSE` 文件，正式复用源码前必须向上游确认许可证。

## 1. 实际主流程

```text
MenuBarExtra / ContentView / 全局 ⌘⇧8
        ↓
Screenshot/AppModel.swift
        ↓
OverlaySelectionController.startSession()
        ↓
每个 NSScreen 创建 OverlayWindow + SelectionOverlayView
        ↓
鼠标拖拽选区
        ↓
CaptureManager.capture(rect:on:excludingWindowIDs:)
        ↓
ScreenCaptureKit 获取显示器首帧
        ↓
裁剪为选区 NSImage
        ↓
SelectionOverlayView.enterEditMode()
        ↓
绘制标注、工具栏、Copy/Save 操作
        ↓
compositeImage()
        ↓
NSPasteboard 或桌面 PNG 文件
```

Hax Shot MVP 可以直接借鉴这条“单次截图 → 框选 → 输出”链路，但 UI 和 Linux 系统调用由 Flutter/Rust 重写。

## 2. AppModel 和入口

关键文件：

- `Screenshot/ScreenshotApp.swift`
- `Screenshot/AppModel.swift`
- `Screenshot/ContentView.swift`

`ScreenshotApp` 使用 SwiftUI `MenuBarExtra` 创建菜单栏入口。`AppModel` 是高层状态和流程控制器，负责：

- 初始化全局快捷键；
- 启动选区 overlay；
- 保存备用编辑器的图片；
- 管理 EditorWindow 和 ShortcutsWindow；
- 持有 `capturedImage`。

实际截图流程以 `OverlaySelectionController` 为主，备用 `EditorView` 并没有接入主流程，不能把目录中的所有文件都当成已完成实现。

## 3. ScreenCaptureKit 截图流程

关键文件：

- `Screenshot/Managers/CaptureManager.swift`
- `Screenshot/Managers/OneFrameCollector.swift`
- `Screenshot/Windows/OverlaySelectionWindow.swift`

`CaptureManager.capture(rect:on:excludingWindowIDs:)` 的步骤：

1. 调用 `SCShareableContent.current` 获取显示器和窗口；
2. 根据 `NSScreenNumber` 匹配目标 `SCDisplay`；
3. 将 overlay 窗口的 `windowNumber` 转成 `CGWindowID`；
4. 构造 `SCContentFilter(display:excludingWindows:)`，排除遮罩窗口；
5. 读取 `CGDisplayMode.pixelWidth/pixelHeight`，设置 stream 输出分辨率；
6. 禁用鼠标和音频；
7. 启动 `SCStream`，由 `OneFrameCollector` 等待第一帧；
8. 立刻停止 stream；
9. `CVPixelBuffer → CIImage → CGImage → NSImage`；
10. 根据截图像素和屏幕 point 尺寸计算 `scaleX/scaleY`；
11. 翻转 Y 轴并裁剪选区；
12. 返回内部保留 Retina 像素的 `NSImage`。

对 Hax Shot 的直接启发：截图 MVP 不需要长期保持录屏流，只获取一张冻结帧即可；但必须保留 `point/pixel/scale` 元数据。

### 必须处理的错误

当前参考项目存在两个不足，Hax Shot 不要照搬：

- `SCShareableContent.current` 失败时基本静默返回 `nil`；
- 首帧始终不到时 continuation 可能一直等待。

Rust 版本需要：

- Portal 权限失败错误；
- 截图超时；
- 没有可用显示器；
- 图片转换失败；
- 剪贴板失败；
- 保存失败。

## 4. 多显示器 Overlay

关键文件：`Screenshot/Windows/OverlaySelectionWindow.swift`

`OverlaySelectionController.presentOverlay()` 遍历 `NSScreen.screens`，每个显示器创建一个无边框 overlay：

```text
.floating
.canJoinAllSpaces
.fullScreenAuxiliary
.stationary
```

行为：

- 所有屏幕同时显示半透明遮罩；
- 用户在哪个屏幕完成选区，就保留哪个 screen 的 overlay；
- 其他 overlay 被隐藏；
- 把所有 overlay 的窗口 ID 传给 CaptureManager 排除。

`SelectionOverlayView` 负责选区绘制：

- 鼠标按下记录起点；
- 拖动更新终点；
- 鼠标释放生成规范化矩形；
- 小于 `4×4` point 的选区直接取消；
- 绘制遮罩、透明选区、白色边框、角点、宽高标签和十字线。

截图成功后，同一个 View 进入 edit mode，而不是再打开一个编辑窗口：

```text
selecting → editing
```

这使最小应用的交互非常直接。Hax Shot MVP 可以用 Flutter 的一个页面完成同样状态切换：

```text
Idle → Selecting → Ready
```

## 5. 全局快捷键

关键文件：`Screenshot/Managers/HotkeyManager.swift`

默认快捷键：

```text
⌘⇧8
```

注册顺序：

1. Carbon `RegisterEventHotKey`；
2. 失败时使用 `NSEvent.addGlobalMonitorForEvents`。

`AppModel.init()` 注册快捷键，Carbon 回调中创建 Task，再调用 `startQuickCapture()`。

可借鉴点：

- 全局快捷键必须放到原生系统层，Flutter 的 `KeyboardListener` 只能接收应用内事件；
- 原生层收到热键后通知 UI 层开始截图；
- 热键对象和事件回调必须保持生命周期。

当前项目存在的缺陷：

- 注册新快捷键时没有完整注销旧 Carbon handler；
- Carbon 注册成功但事件处理器失败时可能遗留 hotkey；
- fallback monitor 没有完善的权限提示；
- 菜单项快捷键和 Carbon 注册可能重复触发。

Hax Shot 的 GNOME Wayland MVP 不复制这套 Carbon 方案，而是由 GNOME 自定义快捷键启动：

```text
Alt+Z → hax_shot --capture
```

## 6. 标注系统

关键文件：

- `Screenshot/Models/AnnotationTypes.swift`
- `Screenshot/Windows/OverlaySelectionWindow.swift`
- `Screenshot/Views/ToolPanelView.swift`

支持：

- 矩形；
- 椭圆；
- 箭头；
- 手绘笔；
- 文字；
- 高亮；
- 数字徽章；
- 选择工具。

Undo/Redo 使用 `AnnotationSnapshot` 保存完整标注数组和 badge counter。

实际绘制使用 AppKit：

- `NSBezierPath`；
- `CGContext`；
- `NSColor`；
- `NSFont`。

`ToolPanelView.swift` 构造底部工具栏和右侧操作面板，操作包括 Copy、Save、Close。

但 Hax Shot 当前 MVP **不实现标注**。保留这个报告是为了未来增加标注时明确参考点，不应因为参考项目有标注就把 MVP 范围扩大。

## 7. 导出和剪贴板

### 剪贴板

关键文件：`Screenshot/Managers/ClipboardManager.swift`

流程：

```text
NSImage
 → TIFF
 → NSBitmapImageRep
 → PNG Data
 → NSPasteboard.general
```

优点：

- 写入 PNG 而不是只写文本；
- 保留 Retina 原始像素；
- 与多数图像应用兼容。

Hax Shot Linux 版本不能使用 Flutter 文本 Clipboard API 代替图片剪贴板，应由 Rust 的 Wayland clipboard service 写入 `image/png`。

### 文件保存

关键文件：`Screenshot/Managers/ExportManager.swift`

支持：

- PNG；
- JPG；
- Desktop 快速保存；
- Downloads 快速保存；
- 原子写入；
- ISO8601 时间命名。

当前 overlay 调用 `quickSaveToDesktop()`，备用 Editor 调用 `quickSaveToDownloads()`，README 和实际代码存在不一致。

`compositeImage()` 的结构值得借鉴：

1. 创建 Retina `NSBitmapImageRep`；
2. 绘制底图；
3. 将标注坐标减去选区原点；
4. 重绘所有标注；
5. 返回最终图片。

Hax Shot 当前没有标注，因此最终图像只是选区裁剪结果；未来增加标注时也应只有一个统一合成出口。

## 8. 未接通代码和阅读边界

以下文件是备用编辑器或早期设计，不是当前主流程：

- `Screenshot/Windows/EditorWindow.swift`
- `Screenshot/Views/EditorView.swift`
- `Screenshot/Managers/LayerManager.swift`
- `Screenshot/Models/Layers.swift`

源码中发现：

- overlay 截图后没有赋值给 `AppModel.capturedImage`；
- `presentEditor()` 没有由主流程调用；
- `EditorView` 只显示图片，画布标注没有完成；
- `LayerManager` 与 overlay 内部标注数组分离；
- `SettingsManager` 的自动复制、声音和默认格式等设置大多未接入；
- 菜单和 UI 写着 Full Screen，但实际主流程是区域选择。

因此，后续 Agent 应优先阅读 `OverlaySelectionWindow.swift`、`CaptureManager.swift`、`ClipboardManager.swift` 和 `ExportManager.swift`，不要把备用 Editor 当作可运行基线。

## 9. 对 Hax Shot 的直接映射

```text
AppModel                         → Flutter CaptureController
OverlaySelectionController      → Flutter SelectionPage
CaptureManager                   → Rust MutterScreenCastService
OneFrameCollector                → Rust 单次截图/超时逻辑
SelectionOverlayView             → Flutter CustomPainter + GestureDetector
ClipboardManager                 → Rust WaylandClipboardService
ExportManager                    → Flutter file_selector + PNG 写文件
HotkeyManager                    → GNOME 自定义快捷键
```

MVP 实现顺序：

1. 先用静态 PNG 完成 Flutter 框选；
2. 用 `CustomPainter` 绘制遮罩和选区；
3. 实现 point → pixel 裁剪；
4. 接入 Rust Mutter ScreenCast + PipeWire 截图；
5. 接入 Rust 图片剪贴板；
6. 接入 `--capture` 启动参数；
7. 配置 GNOME `Alt+Z`；
8. 用真实 GNOME Wayland 完成保存和粘贴验收。

## 10. 工程和许可证

`Screenshot.xcodeproj/project.pbxproj` 显示：

- `LSUIElement = YES`；
- App Sandbox 关闭；
- Hardened Runtime 开启；
- 工程 deployment target 实际为 26.1；
- README 声称支持 macOS 13+，两者不一致。

README 声明使用 MIT License，但本地仓库没有实际 `LICENSE` 文件，版权字段也为空。结论：

- 可以阅读实现思路；
- 不应在 Hax Shot 中直接复制源码；
- 正式复用前需要从上游确认许可证并补齐版权/许可文件。
