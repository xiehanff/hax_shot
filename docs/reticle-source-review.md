# Reticle 源码阅读报告

## 0. 阅读范围

- 仓库：<https://github.com/croc100/Reticle>
- 本地路径：`/home/han/Documents/github/easy_shot/references/reticle`
- 本地浅克隆提交：`8d05dfa`
- 目标：理解接近 Snipaste 的冻结截图、框选、标注、保存、复制和贴图流程。
- 阅读方式：实际阅读关键 Swift 源文件、测试和许可证；本报告不是 README 摘要。

Reticle 是 macOS 原生 SwiftUI/AppKit 项目，不能直接作为 Linux 代码库使用。它最适合提供产品流程和模块边界参考。

## 1. 项目结构

```text
reticle/
├── App/
│   ├── ReticleApp.swift
│   ├── AppDelegate.swift
│   ├── CaptureCoordinator.swift
│   ├── HotkeyManager.swift
│   ├── MenuBarController.swift
│   ├── PinToScreenPanel.swift
│   └── CaptureHistoryManager.swift
├── Sources/
│   ├── ReticleCore/       截图模型、设置、历史、选项
│   ├── ReticleCapture/    ScreenCaptureKit、显示器、窗口、滚动截图
│   ├── ReticleOverlay/    冻结覆盖层、框选、标注画布
│   ├── ReticlePipeline/   Capture → Output → AfterOutput
│   ├── ReticleEffects/    模糊、马赛克、遮罩
│   ├── ReticleVision/     OCR、PII 检测
│   ├── ReticleRecorder/   MP4/GIF 录屏
│   ├── ReticleWorkflow/   快捷键工作流
│   ├── ReticleNaming/     文件名模板解析
│   └── ReticleUploaders/  Imgur/S3/SFTP/HTTP
├── Tests/
├── Package.swift
└── LICENSE
```

`Package.swift` 以 Swift Package 方式构建多个功能模块，主要第三方依赖为：

- `HotKey`：全局快捷键；
- `Defaults`：UserDefaults 封装；
- `Sparkle`：自动更新。

## 2. App 入口和快捷键

### 入口

关键文件：

- `App/ReticleApp.swift`
- `App/AppDelegate.swift`
- `App/Info.plist`
- `App/Reticle.entitlements`

`ReticleApp` 创建并持有：

- `CaptureCoordinator`：截图总协调器；
- `ScreenRecorderController`：录屏；
- `HotkeyManager`：全局快捷键。

`AppDelegate` 将应用设置为 accessory 应用，负责权限引导和 Screen Recording 权限检查。`Info.plist` 使用 `LSUIElement = true`，因此主要表现为菜单栏应用而不是普通 Dock 应用。

### 快捷键

关键文件：`App/HotkeyManager.swift`、`Sources/ReticleCore/AppSettings.swift`

默认快捷键包括：

- 区域截图：`⌘⇧2`；
- 全屏截图：`⌃⌘3`；
- 剪贴板历史：`⌘⇧V`；
- 其他工作流快捷键可动态注册。

`HotkeyManager` 的重要做法：

1. 把 `HotKey` 实例保存在属性中，避免注册后立即释放；
2. 监听设置变化，重新注册快捷键；
3. 将 Carbon modifier flags 和 AppKit modifier flags 做转换；
4. 设置页使用本地 key monitor 录入快捷键。

Linux/GNOME Wayland 不能直接照搬此机制。Easy Shot MVP 使用 GNOME 自定义快捷键调用 `easy_shot --capture`，将系统快捷键和应用截图流程解耦。

## 3. 截图总调用链

Reticle 的区域截图主链路为：

```text
全局快捷键/菜单
  → CaptureCoordinator.captureWithOverlay()
  → runOverlayCapture()
  → CountdownPanel（可选）
  → DisplayProvider.fetchContent()
  → Capturer.capture(.fullScreen)（每个显示器）
  → OverlayWindowController.show()
  → 用户框选
  → OverlayView.requestFinish()
  → OverlayViewModel.renderFinalImage()
  → OverlayViewDelegate
  → CaptureCoordinator.finalize()
  → PipelineRunner
  → 保存、剪贴板、通知、历史、贴图、上传、OCR
```

对 Easy Shot MVP 来说，只保留：

```text
系统快捷键
  → Rust 获取冻结屏幕图
  → Flutter 框选
  → 裁剪
  → 保存 PNG / 复制图片剪贴板
```

## 4. ScreenCaptureKit 捕获实现

关键文件：

- `Sources/ReticleCapture/Capturer.swift`
- `Sources/ReticleCapture/CaptureMode.swift`
- `Sources/ReticleCapture/DisplayProvider.swift`
- `Sources/ReticleCapture/FrameCapture.swift`
- `Sources/ReticleCapture/ImageConverter.swift`

### Capturer

`Capturer` 是 actor，支持：

```text
.region(CGRect)
.window(CGWindowID)
.fullScreen(displayID:)
```

区域截图不是直接传入一个可能有歧义的区域给 ScreenCaptureKit，而是：

1. 捕获完整显示器；
2. 根据区域坐标裁剪。

这点非常重要：冻结画面和最终裁剪使用同一份原始图，避免二次截图期间画面变化。

### FrameCapture

`FrameCapture` 负责从 `SCStream` 获取一张完整帧：

- 忽略无效帧；
- 只接受 `.complete` 帧；
- 使用 `CheckedContinuation` 等待首帧；
- 使用锁保护 continuation；
- 5 秒超时，避免无限等待。

### ImageConverter

转换链为：

```text
CMSampleBuffer
  → CVPixelBuffer
  → CIImage
  → GPU CIContext
  → CGImage
```

Linux Rust 版本不需要模仿 CoreImage，但需要保留“原始像素图 → 标准图像对象/PNG”的清晰边界。

### DisplayProvider

负责：

- 查询显示器和窗口；
- 根据区域和显示器交集选择显示器；
- 根据窗口 ID 查窗口；
- 获取 Retina backing scale。

Easy Shot MVP 第一阶段只保证 GNOME Wayland 单显示器，仍然要在数据结构中保留 `pixelWidth/pixelHeight/scale`，避免以后重写坐标模型。

## 5. 冻结覆盖层和框选

关键文件：

- `Sources/ReticleOverlay/OverlayWindowController.swift`
- `Sources/ReticleOverlay/OverlayView.swift`
- `Sources/ReticleOverlay/OverlayViewModel.swift`

### OverlayWindowController

每个显示器创建一个无边框透明 `NSWindow`：

- 最高窗口级别；
- `canJoinAllSpaces`；
- `fullScreenAuxiliary`；
- `stationary`；
- 窗口背景放置已经捕获的冻结图片。

多个显示器共享一个 `OverlayViewModel`，工具栏显示在鼠标所在显示器。

这里最值得借鉴的不是 AppKit API，而是流程：**先拿到冻结图，再在冻结图上做框选**。Easy Shot 用 Flutter 显示冻结 PNG，Rust 只负责原始截图和 PNG 处理。

### OverlayView

框选行为包括：

- 鼠标拖动超过最小尺寸后产生选区；
- 单击悬停窗口可以捕获窗口；
- 双击或 Enter 完成；
- Escape 或右键取消；
- 十字线；
- 宽高和像素坐标 HUD；
- 8 个缩放手柄；
- Shift 约束比例/角度。

Easy Shot MVP 只保留：

- 左键拖拽；
- 有效矩形选区；
- Escape 取消；
- 保存、复制按钮。

### 最终图像

`requestFinish()` 主要做三件事：

1. 应用二次裁剪；
2. 根据 `baseCGImage.width / bounds.width` 计算真实像素缩放；
3. 调用 `renderFinalImage()` 生成最终图片。

这提醒 Easy Shot：Flutter 的逻辑像素选区不能直接作为 PNG 裁剪坐标，必须转换为物理像素。

## 6. 标注模型和绘制

虽然 Easy Shot MVP 暂不实现标注，仍需要了解 Reticle 的模型边界。

关键文件：

- `Sources/ReticleOverlay/Editor/Annotation.swift`
- `Sources/ReticleOverlay/OverlayView.swift`
- `Sources/ReticleOverlay/OverlayViewModel.swift`

基础 `Annotation` 提供：

- 颜色；
- 线宽和线型；
- 旋转；
- 包围盒；
- `draw(in:)`；
- `hitTest(_:)`；
- 旋转绘制。

标注类型包含：

- 矩形、椭圆、直线、箭头；
- 画笔、尺子、步骤编号；
- 文字、气泡、Emoji、图片；
- 高亮、模糊、马赛克、黑遮罩、聚光灯、放大镜。

`OverlayViewModel` 在最终导出时：

1. 按像素边界裁剪原图；
2. 处理模糊、马赛克、遮罩和放大镜；
3. 通过 Core Graphics 绘制矢量标注；
4. 返回最终 `CGImage`。

未来 Easy Shot 增加标注时，应使用 Rust 的可序列化值类型，而不是复制 Swift 的引用类型：

```text
Annotation {
  type,
  rect/start/end/points,
  color,
  width,
  rotation,
  text,
  effectParameters
}
```

## 7. 保存、复制和 Pipeline

关键文件：

- `Sources/ReticlePipeline/CaptureTask.swift`
- `Sources/ReticlePipeline/PipelineRunner.swift`
- `Sources/ReticlePipeline/ClipboardOutput.swift`
- `Sources/ReticlePipeline/LocalFileOutput.swift`
- `App/CaptureCoordinator.swift`

### Pipeline

Reticle 将流程拆成：

```text
BeforeCapture
  → Capture
  → AfterCapture
  → Output
  → AfterOutput
```

`CaptureContext` 记录 workflow ID、触发时间和输出文件。

Easy Shot MVP 不需要实现完整插件化 Pipeline，但可以保留一个简单的服务边界：

```text
CaptureService
  → CropService
  → OutputService.savePng / ClipboardService.copyPng
```

### 剪贴板

`ClipboardOutput.swift`：

- 将图像转换为带 point size 的对象；
- 在主线程访问系统剪贴板；
- 使用图像对象写入剪贴板。

Linux/GNOME Wayland 不能使用 Flutter 的文本剪贴板接口来保证图片复制。Easy Shot 应由 Rust 使用 Wayland 图片剪贴板实现，并明确传入 `image/png`。

### 文件保存

`LocalFileOutput.swift`：

- 支持 PNG/JPEG/TIFF/WebP；
- 按日期分目录；
- 设置 DPI：`scaleFactor × 72`；
- 后处理任务负责打开 Finder、复制路径等。

Easy Shot MVP 只支持 PNG 和用户选择路径，不加入日期目录、DPI 和后处理任务。

## 8. 贴图、历史和扩展功能

### PinToScreenPanel

文件：`App/PinToScreenPanel.swift`

- 每次 Pin 创建独立 `NSPanel`；
- `isFloatingPanel = true`；
- `level = .floating`；
- 可以同时存在多个贴图；
- 静态数组保持窗口生命周期；
- 关闭时从数组移除。

这正是 Snipaste 的核心体验之一，但不进入 Easy Shot 当前 MVP。未来实现时，Linux Wayland 的“全局置顶窗口”不是标准能力，应单独作为桌面环境兼容任务。

### 历史和缩略图

- `CaptureHistoryManager.swift` 持久化 JSON 历史；
- `ThumbnailController.swift` 显示临时缩略图；
- `ClipboardHistoryManager.swift` 轮询剪贴板变更。

这些全部排除在 MVP 外。

## 9. 源码中发现的工程问题

阅读源码时记录了以下问题，后续移植不要照搬：

1. `AppSettings.swift` 提供 `filenamePattern`，但 `CaptureCoordinator` 创建 `LocalFileOutput` 时没有传入它，实际仍使用默认文件名。
2. `AutoCaptureMode.fullScreen` 的标题表示全显示器，但 `runFullScreen()` 实际使用 `CGMainDisplayID()`，只捕获主显示器。
3. `OverlayViewModel` 的 Undo 只复制 `[Annotation]` 数组，而 Annotation 是引用类型，移动/缩放可能无法真正恢复旧几何状态。
4. `finalize()` 中部分通知、历史、Pin、上传和 OCR 使用原始图片，而不是经过遮罩/水印后的最终图片。
5. Annotation 没有 Codable，标注不能保存为工程文件。

## 10. 对 Easy Shot 的直接结论

### 保留

- 完整屏幕冻结后裁剪；
- UI 坐标和图像像素坐标分离；
- 捕获、裁剪、输出分层；
- 保存和复制是两个独立输出动作；
- 错误必须有超时和可读提示。

### 不照搬

- SwiftUI/AppKit overlay；
- macOS ScreenCaptureKit；
- `HotKey`/Carbon 全局快捷键；
- `NSPanel` 贴图；
- Reticle 的完整 Pipeline、历史、上传、OCR。

### 当前 MVP 映射

```text
Reticle Capturer             → Rust Wayland Portal CaptureService
Reticle OverlayView          → Flutter SelectionCanvas
Reticle renderFinalImage     → Flutter 选区裁剪 / Rust PNG 处理
Reticle LocalFileOutput      → Flutter file_selector + PNG 写文件
Reticle ClipboardOutput      → Rust Wayland ClipboardService
Reticle HotkeyManager        → GNOME 自定义快捷键启动 easy_shot --capture
```

## 11. 许可证

`references/reticle/LICENSE` 不是单纯 Apache-2.0，而是：

```text
Apache License 2.0
+ Commons Clause License Condition v1.0
```

Commons Clause 明确不授予出售软件的权利。结论：

- 可以阅读和参考设计；
- 不应把 Reticle 代码直接复制到 Easy Shot；
- 不要把它宣传为“纯 Apache-2.0”；
- 如未来必须复用代码，需要单独进行许可证合规审查。
