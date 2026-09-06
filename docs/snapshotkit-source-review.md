# SnapShotKit 源码阅读报告

## 0. 阅读范围

- 仓库：<https://github.com/bheemrc/SnapShotKit>
- 本地路径：`/home/han/Documents/github/hax_shot/references/snapshotkit`
- 本地浅克隆提交：`d13699b`
- 许可证：MIT
- 目标：研究轻量原生截图、坐标规范、统一导出和剪贴板实现。

SnapShotKit 是 SwiftUI + AppKit 的 macOS 原生应用，没有第三方 SwiftPM 依赖。它的代码比 Reticle 更适合参考“最小清晰模块”，尤其是像素坐标和 flatten 设计。

## 1. 项目结构和入口

```text
snapshotkit/
├── Package.swift
├── Sources/SnapShotKit/
│   ├── SnapShotKitApp.swift
│   ├── AppState.swift
│   ├── CaptureEngine.swift
│   ├── CaptureModes.swift
│   ├── RegionSelectionOverlay.swift
│   ├── AnnotationModels.swift
│   ├── AnnotationCanvas.swift
│   ├── PDFExporter.swift
│   ├── ExportService.swift
│   ├── OCRService.swift
│   ├── RedactionService.swift
│   ├── CapturePersistence.swift
│   ├── PinnedWindowController.swift
│   └── ...
├── Tests/SnapShotKitTests/ExportTests.swift
├── LICENSE
├── make-app.sh
└── make-dmg.sh
```

`Package.swift`：

- Swift tools 6.0；
- macOS 14+；
- 一个可执行目标 `SnapShotKit`；
- 一个测试目标；
- 没有第三方 SwiftPM 依赖。

`SnapShotKitApp.swift` 使用 `@NSApplicationDelegateAdaptor` 接入 AppKit，创建 SwiftUI `WindowGroup`。AppDelegate 负责菜单栏、面板和全局快捷键。

`make-app.sh` 将 SwiftPM 二进制包装为稳定 Bundle ID 的 `.app` 并执行 ad-hoc 签名。这一点是 macOS TCC 屏幕录制权限能够稳定关联到应用的关键，但与 Linux MVP 无关。

## 2. 总体调用关系

```text
AppDelegate / ContentView / MenuBarPanel
                    |
                    v
                AppState
                    |
       +------------+-------------+----------------+
       |                          |                |
 CaptureEngine              RegionSelectionOverlay RecordingEngine
       |                          |                |
 ScreenCaptureKit       CaptureEngine.captureRegion ScreenCaptureKit
       |
 CaptureItem(image + annotations)
       |
 AnnotationCanvas
       |
 PDFExporter.flatten
       |
 +------+-------------------+------------------+
 |                          |                  |
ExportService          BackgroundStyler   PinnedWindowController
 |                          |
PNG / Clipboard          背景合成
```

`AppState` 是主状态容器，标记为 `@MainActor`，持有：

- `captures`；
- 当前选中项；
- 捕获状态和错误；
- 背景样式；
- 录屏引擎；
- recents；
- OCR、脱敏、保存和导出动作。

Hax Shot MVP 不需要完整的 `AppState` 单例，可以拆成 Flutter 的页面状态和 Rust 的平台服务。

## 3. 屏幕捕获

### 全屏捕获

关键文件：`Sources/SnapShotKit/CaptureEngine.swift`

流程：

1. `SCShareableContent.current` 获取可分享内容；
2. 选择主显示器；
3. 创建 `SCContentFilter(display:excludingWindows:)`；
4. 查询 `NSScreen.backingScaleFactor`；
5. 配置 ScreenCaptureKit，关闭缩放并输出 Retina 原始像素；
6. 通过 `SCScreenshotManager.captureImage` 得到 `CGImage`；
7. 封装成 point 逻辑尺寸 + 原始像素的 `NSImage`。

### 区域捕获

关键文件：`Sources/SnapShotKit/CaptureModes.swift`

区域捕获使用以下坐标转换：

```text
AppKit 全局坐标：bottom-left / y-up / point
        ↓
目标显示器本地坐标：top-left / y-down / point
        ↓
ScreenCaptureKit sourceRect
        ↓ scale
bitmap：top-left / y-down / pixel
```

窗口捕获只传递 `CGWindowID`，真正捕获时重新解析窗口，避免跨 actor 传递非 Sendable 的 `SCWindow`。

这对 Hax Shot 的直接意义：桥接接口不能只返回图片，还应返回：

```text
pixelWidth
pixelHeight
logicalWidth
logicalHeight
scaleX
scaleY
```

## 4. 选区覆盖层

关键文件：`Sources/SnapShotKit/RegionSelectionOverlay.swift`

实现方式：

- 每个显示器创建一个无边框 `NSPanel`；
- 窗口级别为 `.screenSaver`；
- 支持跨 Space 和全屏应用；
- 使用 `.nonactivatingPanel`，避免把用户切回应用所在 Space；
- 使用半透明黑色遮罩，选区内部透明；
- 显示物理像素宽高；
- Esc 或空选区取消；
- `static active` 强引用当前活动实例；
- `didFinish` 保证 completion 只执行一次；
- 先关闭 overlay，再执行捕获回调，防止 overlay 被截入截图。

Hax Shot 使用 Flutter 画面模拟冻结背景，因此不需要完全复制 AppKit 的清除绘制方式，但必须保留两个原则：

1. 交互层和截图源要有明确关系；
2. 结束选区前不能让 overlay 自身进入最终截图。

在 GNOME Wayland MVP 中，Rust 先获取冻结 PNG，Flutter 再打开当前屏幕的框选窗口，避免实现实时透明屏幕捕获 overlay。

## 5. 坐标系统：最重要的设计

源码明确区分：

| 场景 | 坐标 |
|---|---|
| AppKit 全局屏幕 | bottom-left，y-up，point |
| ScreenCaptureKit sourceRect | 显示器本地 top-left，point |
| bitmap | top-left，y-down，pixel |
| SwiftUI Canvas | top-left，y-down |
| Vision bounding box | normalized bottom-left |
| PDF/AppKit 绘制 | bottom-left，y-up |

`Annotation` 永远保存为图片像素坐标、左上角原点。只有 `PDFExporter.swift` 在导出 PDF 时进行 y-flip，其他模块不重复翻转。

Hax Shot 应进一步简化为：

```text
Flutter UI：top-left / y-down / logical point
Rust image：top-left / y-down / pixel
桥接处只做一次 point → pixel 转换
```

即使当前 MVP2 已有标注，也要按这个规则计算选区裁剪，否则高 DPI 或非 100% 缩放时 PNG 内容会偏移。

## 6. 标注模型和统一 flatten

### 模型

关键文件：`Sources/SnapShotKit/AnnotationModels.swift`

```text
CaptureItem
  id
  image
  annotations
  title

Annotation
  id
  kind
  start
  end
  text
  colorHex
  points
  number
  lineWidth
```

支持箭头、矩形、直线、椭圆、文字、高亮、画笔、模糊和步骤编号。标注保存像素坐标，因此画布缩放不会损坏位置。

### 画布

关键文件：`Sources/SnapShotKit/AnnotationCanvas.swift`

- 使用 `FitTransform` 完成图片像素和画布坐标的双向转换；
- 所有手势点 clamp 到图片范围；
- 支持文字和步骤编号；
- 支持自由笔；
- 使用完整数组快照做 undo/redo；
- 反向命中测试，使顶部标注优先；
- 预览中的 Blur 只是占位，真实处理延迟到导出。

### flatten 单一真源

关键文件：`Sources/SnapShotKit/PDFExporter.swift`

`PDFExporter.flatten(_:)` 负责：

1. 创建完整像素尺寸的位图；
2. 绘制原图；
3. 绘制所有标注；
4. 统一做坐标翻转；
5. 对 Blur 使用 Core Image `CIPixellate`；
6. 输出最终图像。

PNG、剪贴板、OCR、Pin、PDF、PPTX 都复用 flatten 结果。

这是 Hax Shot 当前必须保留的原则：**原图和标注模型分离，最终保存和复制共享同一个渲染出口**。MVP2 的矩形、箭头和文字已经通过 `CapturePage._renderSelection()` 统一合成。

## 7. 保存和剪贴板

关键文件：`Sources/SnapShotKit/ExportService.swift`

特点：

- 优先使用最高分辨率 `NSBitmapImageRep`；
- 剪贴板优先写 PNG 数据，保留 Retina 像素；
- 使用系统保存面板；
- 快速保存到 Desktop；
- 文件名清理特殊字符并自动避免重名。

调用路径：

```text
AppState.copySelectedToClipboard()
    → PDFExporter.flatten()
    → BackgroundStyler.render()
    → ExportService.copyToPasteboard()
```

Hax Shot MVP：

- Flutter 用 `file_selector` 打开保存路径选择；
- Rust/Wayland 负责图片剪贴板；
- 统一只输出 PNG；
- 复制失败不能静默关闭窗口，应返回可读错误。

## 8. Recents 持久化

关键文件：`Sources/SnapShotKit/CapturePersistence.swift`

SnapShotKit 将原始 PNG 保存到：

```text
~/Library/Application Support/SnapShotKit/recents
```

当前只保存原始图片和标题文件名，不保存标注、ID、undo/redo 状态。源码还存在一个问题：`AppState.captureWindow(id:)` 成功后没有调用 `persistRecents()`，窗口截图不会立即进入历史。

Hax Shot 当前 MVP 不实现历史，但未来应使用：

```text
capture.png
capture.json
```

JSON 保存尺寸、scale、选区和标注，避免只保存图片导致元数据丢失。

## 9. 菜单栏、快捷键和贴图

### 菜单栏

关键文件：

- `SnapShotKitApp.swift`
- `CapturePanelController.swift`
- `MenuBarPanel.swift`

实际是 `NSPanel + NSHostingView` 的浮动面板，左键打开 SwiftUI 面板，右键打开完整菜单。捕获前会关闭面板并等待约 0.25 秒，避免面板进入截图。

### 快捷键

关键文件：`Sources/SnapShotKit/HotkeyManager.swift`

使用 Carbon `RegisterEventHotKey`，默认包括：

- `⌘⇧\\`：全屏；
- `⌘⇧2`：区域；
- `⌘⇧6`：录屏；
- `⌘⇧Space`：面板。

Carbon 回调使用非 owning 指针，因此 `AppDelegate` 必须强引用 `HotkeyManager`。

### Pin

关键文件：`Sources/SnapShotKit/PinnedWindowController.swift`

- 浮动 `NSPanel`；
- 可跨 Space 和全屏应用；
- 多个截图自动级联；
- 支持拖动、Esc 和关闭；
- 控制器强引用所有窗口。

Pin 不属于 Hax Shot 当前 MVP，但未来实现时要保留“管理器持有独立窗口对象”的生命周期设计。

## 10. 其他功能及其取舍

### OCR

`OCRService.swift` 使用 Vision `VNRecognizeTextRequest`，按阅读顺序返回文本。Linux 版本可在后续通过 Tesseract/ocrs 实现，当前不加入。

### 自动脱敏

`RedactionService.swift` 将 OCR 正则和人脸检测结果转换成像素坐标的 Blur 标注。当前不加入。

### 录屏和滚动截图

- `RecordingEngine.swift`：SCStream + AVAssetWriter，30 FPS H.264；
- `ScrollingCaptureEngine.swift`：模拟滚轮、重复捕获、通过亮度签名查找重叠行。

二者都需要额外权限和大量桌面兼容工作，不进入 Hax Shot MVP。

## 11. 源码中发现的问题

1. 窗口截图成功后没有立即持久化 recents。
2. 手工标注不跨重启保存。
3. OCR 虽包装成 async，但核心 Vision 调用可能仍阻塞当前执行线程。
4. 大图导出在主 actor 上运行，可能阻塞 UI。
5. `AnnotationCanvas` 对自由笔迹命中测试不够精确。
6. `CIPixellate` 是像素化，不是传统模糊，产品文案需要区分。
7. README 关于“无 Dock 图标”的描述与 `LSUIElement=false`/regular activation policy 存在不一致。

这些问题说明 Hax Shot MVP 不应复制完整项目，而应只抽取坐标、图像输出和状态边界。

## 12. 对 Hax Shot 的直接结论

### 推荐映射

```text
CaptureEngine                 → Rust PortalCaptureService
RegionSelectionOverlay        → Flutter SelectionPage
AnnotationModels              → 未来 Rust serde 模型
AnnotationCanvas              → 未来 Flutter CustomPainter
PDFExporter.flatten           → 未来统一 RenderService
ExportService.copyToPasteboard→ Rust Wayland ClipboardService
PinnedWindowController        → 未来 Linux 窗口服务
HotkeyManager                 → GNOME 系统自定义快捷键
```

### 当前 MVP 保留

1. 全屏冻结图；
2. Flutter 框选；
3. point → pixel 裁剪；
4. PNG 保存；
5. PNG 图片剪贴板；
6. Escape 取消；
7. 明确的错误状态和超时。

### 当前 MVP 排除

- 标注；
- 历史；
- Pin；
- OCR；
- 录屏；
- 滚动截图；
- PDF/PPTX/GIF。

## 13. 许可证

`references/snapshotkit/LICENSE` 为 MIT License：

```text
Copyright (c) 2026 Bheema Rajulu
```

如果未来直接复制其代码，应保留 MIT 许可证和版权声明。当前 Hax Shot 只参考架构和实现思路，不直接复制 Swift 代码。
