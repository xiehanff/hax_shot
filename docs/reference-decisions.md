# Easy Shot 参考源码结论

## 1. 参考仓库选择

| 参考项目 | 在 Easy Shot 中参考什么 | 不参考什么 |
|---|---|---|
| Reticle | 冻结画面、框选、输出流水线、贴图产品体验 | Swift/AppKit、ScreenCaptureKit、完整功能 |
| SnapShotKit | point/pixel 坐标规范、统一 flatten、PNG/剪贴板输出 | macOS TCC、Carbon、SwiftUI 代码 |
| Screenshot | 最小主链路、单帧捕获、排除 overlay、Save/Copy | 未接通的 Editor/LayerManager、缺少错误处理的部分 |

## 2. Easy Shot MVP 的最终边界

```text
GNOME 系统快捷键 Alt+Z
  → easy_shot --capture
  → Rust 通过 Mutter ScreenCast + PipeWire 获取无快门声冻结屏幕图
  → Flutter 显示冻结图并拖拽框选
  → 保存 PNG / 复制 image/png 剪贴板
```

### 必须实现

- `--capture` 启动参数；
- GNOME 自定义快捷键触发；
- GNOME Wayland 单显示器；
- 当前屏幕冻结图；
- 矩形框选；
- Escape 取消；
- PNG 保存路径选择；
- PNG 图片剪贴板；
- 截图失败、权限失败和超时提示；
- Proton Pass 图标的 GNOME 托盘集成；应用常驻托盘，不显示主应用窗口。

### 明确不实现

- 标注；
- 贴图窗口；
- 多显示器；
- 窗口截图；
- OCR；
- 滚动截图；
- 录屏；
- 历史；
- 云上传；
- X11 兼容。

## 3. 目标架构

```text
┌──────────────────────────────────────────────┐
│ Flutter                                      │
│ CapturePage / SelectionCanvas / Toolbar      │
│ - 冻结图显示                                  │
│ - 鼠标框选                                    │
│ - 选区状态                                    │
│ - 保存路径选择                                │
│ - 成功/失败提示                               │
└──────────────────┬───────────────────────────┘
                   │ Dart FFI / Rust C ABI
┌──────────────────▼───────────────────────────┐
│ Rust                                         │
│ CaptureService / ClipboardService / PNG      │
│ - Mutter ScreenCast + GStreamer PipeWire    │
│ - Wayland image/png clipboard                │
│ - 截图超时和错误                              │
│ - point → pixel 元数据                       │
└──────────────────────────────────────────────┘
```

### Flutter 层

建议目录：

```text
lib/
├── main.dart
├── app.dart
├── native/native_bridge.dart
└── features/capture/
    ├── capture_page.dart
    ├── capture_controller.dart
    ├── capture_state.dart
    ├── screenshot_canvas.dart
    └── capture_toolbar.dart
```

### Rust 层

```text
rust/
└── src/
    ├── lib.rs
    ├── capture.rs
    ├── clipboard.rs
    └── error.rs
```

## 4. 状态机

```text
Idle
  ↓ --capture
Capturing
  ↓ PNG ready
Selecting
  ├── Esc → Closed
  └── valid rectangle → Ready
                         ├── Save → Saving → Closed
                         └── Copy → Copying → Closed
```

按钮规则：

- 没有有效选区时，Save/Copy 禁用；
- Save/Copy 期间防止重复点击；
- 成功后关闭窗口；
- 失败时保留选区，让用户重试。

## 5. 坐标约定

从 SnapShotKit 和 Reticle 的源码中确定：

```text
Flutter UI：top-left origin / y-down / logical point
Rust image：top-left origin / y-down / physical pixel
```

选区换算：

```text
pixelRect.left   = logicalRect.left   × scaleX
pixelRect.top    = logicalRect.top    × scaleY
pixelRect.width  = logicalRect.width  × scaleX
pixelRect.height = logicalRect.height × scaleY
```

必须：

- 对矩形做 normalize；
- clamp 到冻结图边界；
- 使用物理像素裁剪；
- 不在 Dart 和 Rust 两边重复翻转 Y 轴；
- 后续增加标注时也使用选区本地坐标。

## 6. 原生能力边界

Flutter 不直接执行：

- `wl-copy`；
- `grim`；
- `gnome-screenshot`；
- Mutter D-Bus 调用；
- Wayland 协议。

这些统一放到 Rust 中。Flutter 只调用抽象接口：

```dart
abstract final class NativeBridge {
  static Future<String> captureScreen();
  static Future<void> copyPngToClipboard(Uint8List pngBytes);
}
```

当前 MVP 可以让 `captureScreen()` 返回临时 PNG 路径，避免通过 FFI 复制大块图片；Flutter 读取 PNG 后完成显示和裁剪。

## 7. 来源代码带来的关键经验

### 冻结后裁剪

Reticle、Screenshot 和 GNOME 原生截图 UI 都采用“先拿完整屏幕帧，再裁剪”，而不是框选结束后重新截屏。这样可以：

- 避免窗口内容变化；
- 避免选区遮罩进入截图；
- 让框选和最终输出使用同一张图。

### Overlay 排除

macOS 参考项目将 overlay 窗口 ID 从 ScreenCaptureKit 捕获内容中排除。Easy Shot 在 Flutter 窗口显示前通过 Mutter ScreenCast 获取冻结帧，再显示选区窗口，不能把正在显示的 UI 当成截图源。

### 单一输出真源

SnapShotKit 的 `PDFExporter.flatten` 让 PNG、剪贴板、Pin 和导出共用同一份最终图。Easy Shot MVP 当前没有标注，但保存和复制必须都使用同一份裁剪后的 PNG 字节，不能分别生成两份结果。

### 错误不能静默

参考项目中存在 `nil` 静默返回和首帧无限等待问题。Easy Shot 必须加入：

- Mutter ScreenCast/GStreamer 不可用；
- 捕获超时；
- PNG 解码失败；
- 选区无效；
- 文件保存失败；
- 剪贴板失败。

## 8. 许可证结论

- `Reticle`：Apache-2.0 + Commons Clause。仅作设计参考，不直接复制代码。
- `SnapShotKit`：MIT。如未来复用代码，保留版权和 MIT 文本。
- `Screenshot`：README 声称 MIT，但本地缺少 LICENSE 正文；在上游确认前不复制代码。

## 9. 给后续 Agent 的阅读顺序

1. 先读本文件；
2. 再读 `mvp.md`；
3. 需要完整产品流程时读 `reticle-source-review.md`；
4. 需要坐标和图片输出时读 `snapshotkit-source-review.md`；
5. 需要轻量主链路时读 `screenshot-source-review.md`；
6. 真正实现 Linux 时，参考仓库只提供行为，不能把 macOS API 名称直接当成 Linux API。
