# Hax Shot Flutter + Rust MVP1 方案

> 本文记录基础截图链路的 MVP1 方案和历史验收标准。当前 MVP2 已增加自启动、矩形、箭头和文字标注；发布安装包（DMG/DEB/RPM）的流程见 [`docs/ci-release.md`](docs/ci-release.md)。参考源码阅读报告见 [`docs/README.md`](docs/README.md)，实现前先阅读 `docs/reference-decisions.md`。

## 1. 目标

在 Linux 桌面实现一个最小可用的截图工具：

1. 通过组合快捷键触发截图；
2. 显示当前屏幕的冻结画面；
3. 鼠标拖拽框选截图区域；
4. 工具栏支持保存到本地路径；
5. 点击复制按钮，将 PNG 图片复制到系统剪贴板；
6. 普通启动只驻留托盘，支持 Hax Shot 图标和托盘菜单。

本版本只解决“快捷键截图 → 框选 → 保存/复制”这条主链路，不追求 Snipaste 的完整功能。

## 2. 项目位置

```text
/home/han/Documents/github/hax_shot
```

运行 Flutter 空项目：

```bash
cd /home/han/Documents/github/hax_shot
fvm flutter run -d linux
```

## 3. 技术边界

```text
Flutter
├── 截图冻结画面
├── 鼠标框选 UI
├── 工具栏
├── 保存路径选择
└── 状态提示
        │ Dart FFI / Rust C ABI
Rust
├── Linux 截图
├── Wayland 剪贴板
└── 后续的 X11 兼容
```

### Flutter 负责

- 截图预览窗口；
- 选区绘制和鼠标交互；
- 选区裁剪后的图片展示；
- 保存文件对话框；
- 保存、复制、取消按钮；
- 错误和成功提示。

### Rust 负责

- 通过 Mutter `ScreenCast` + PipeWire 获取无快门声的单帧屏幕；
- 将截图转换为 PNG 或临时文件；
- 将 PNG 写入 Wayland 图片剪贴板；
- 屏蔽 Linux 平台 API，不让 Flutter 页面直接调用系统命令。

## 4. Linux MVP 范围

当前开发环境是 **GNOME + Wayland**，第一版只保证该环境。

### 截图方式

使用 GNOME 原生截图 UI 相同的思路：先通过 Mutter `ScreenCast` 抓取一帧
PipeWire 画面，再由 Flutter 显示冻结画面、黑色半透明遮罩和框选控件。这样
不会调用 XDG Screenshot Portal 的快门动画或相机声音。

不要依赖 `gnome-screenshot`、`grim` 或 `slurp` 作为核心实现：

- `grim/slurp` 主要面向 wlroots 桌面；
- GNOME Mutter 不提供 `wlr-screencopy`；
- XDG Screenshot Portal 会触发 GNOME 的截图闪光/声音；
- MVP 只保证 GNOME + Wayland，并要求 Mutter ScreenCast 和 GStreamer PipeWire 插件。

### 快捷键方式

Wayland 下应用不能可靠地自行注册任意全局快捷键。因此 MVP 使用 GNOME 系统快捷键调用应用的 `--capture` 参数：

```text
Alt + Z
    ↓
启动 hax_shot --capture
    ↓
Rust 通过 Mutter ScreenCast 获取无快门声帧
    ↓
Flutter 打开黑色半透明框选窗口
```

在 GNOME 中增加自定义快捷键：

- 名称：`Hax Shot`
- 命令：`/项目构建路径/hax_shot --capture`
- 快捷键：`Alt+Z`

这样组合键仍然可以触发框选，同时避免在 Wayland 下实现不可靠的进程内全局热键监听。

## 5. 用户流程

```text
启动 --capture
    ↓
Mutter ScreenCast 获取一帧画面（不播放截图声音）
    ↓
打开当前屏幕的冻结图片
    ↓
鼠标按下并拖动
    ↓
形成矩形选区
    ↓
显示工具栏：取消 / 保存 / 复制
    ├── 取消：关闭窗口，不产生文件
    ├── 保存：选择本地路径并写入 PNG
    └── 复制：写入系统图片剪贴板，然后关闭窗口
```

快捷键：

- `Esc`：取消当前截图；
- 鼠标左键拖拽：创建选区；
- 鼠标释放：确认选区；
- `Alt+Z`：由 GNOME 系统快捷键触发。

## 6. Flutter UI 设计

### 页面结构

```text
CapturePage
├── ScreenshotCanvas
│   ├── 冻结截图背景
│   ├── 半透明遮罩
│   └── 选区边框
└── CaptureToolbar
    ├── 取消
    ├── 保存
    └── 复制
```

### 选区实现

使用 `CustomPainter` 绘制：

- 全屏半透明黑色遮罩；
- 当前拖拽矩形；
- 选区外区域继续显示遮罩；
- 选区内显示原始冻结图片；
- 可选显示选区宽高。

截图坐标必须区分：

```text
Flutter 逻辑像素坐标
        ↓ scaleX / scaleY
截图实际物理像素坐标
```

保存和复制时使用物理像素裁剪，避免高 DPI 屏幕截图尺寸错误。

### 工具栏

有效选区生成后，工具栏参照 Plume PDF AI 框选工具栏定位：优先放在选区下方，
下方空间不足时放到上方；如果选区几乎占满屏幕，则放在选区中心。水平方向始终跟随选区中心，靠近屏幕边缘时再做边界裁剪。工具栏使用
`CustomSingleChildLayout` 获取实际尺寸，避免按钮文字变化导致位置判断失准。

MVP 工具栏只保留三个控件：

| 按钮 | 行为 |
|---|---|
| 取消 | 关闭截图窗口 |
| 保存 | 打开保存路径选择器，默认 PNG |
| 复制 | 将选区 PNG 写入系统剪贴板 |

不加入箭头、文字、马赛克、贴图、OCR 等功能。

## 7. 推荐目录结构

```text
hax_shot/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── features/
│   │   ├── capture/
│   │   │   ├── capture_page.dart
│   │   │   ├── capture_toolbar.dart
│   │   │   ├── screenshot_canvas.dart
│   │   │   └── selection_toolbar_placement.dart
│   │   └── settings/
│   │       └── shortcut_settings_page.dart
│   └── native/
│       └── native_bridge.dart
├── rust/
│   ├── src/lib.rs
│   └── README.md
├── linux/
├── mvp.md
└── pubspec.yaml
```

## 8. Native Bridge 接口

Flutter 只依赖抽象接口，不直接执行 `wl-copy`、Mutter D-Bus 或 GStreamer：

```dart
abstract final class NativeBridge {
  static Future<String> captureScreen();

  static Future<void> copyPngToClipboard(Uint8List pngBytes);
}
```

返回值约定：

- `captureScreen`：返回临时 PNG 文件路径；
- `copyPngToClipboard`：成功返回，失败抛出带用户可读信息的异常。

MVP 阶段优先传递临时文件路径，避免大尺寸截图通过 FFI 反复复制；复制到剪贴板时再读取 PNG 字节。

## 9. 依赖计划

### Flutter

- `dart:ffi` + `ffi`：Flutter 调用 Rust C ABI；
- `file_selector`：保存路径选择；
- `window_manager`：Linux 窗口尺寸和全屏控制；
- `tray_manager`：GNOME AppIndicator 托盘图标和菜单。

### Rust

- `zbus`：调用 Mutter ScreenCast D-Bus 接口；
- `gstreamer`：通过 `pipewiresrc` 获取一帧并用 `pngenc` 编码；
- `tokio`：同步 FFI 入口中的异步 D-Bus runtime；
- 系统 `wl-copy`：GNOME Wayland 图片剪贴板；
- Rust `cdylib` + C ABI 导出。

实际添加依赖时应锁定当前稳定版本，不在 MVP 文档中预设版本号。

## 10. 状态机

```text
Idle
  ↓ --capture
Capturing
  ↓ 截图完成
Selecting
  ↓ 选区有效
Ready
  ├── 保存 → Saving → Closed
  ├── 复制 → Copying → Closed
  └── 取消 → Closed
```

异常状态统一回到 `Idle` 或关闭当前截图窗口，并显示错误原因。

## 11. MVP 验收标准

### 必须通过

- [ ] 使用 GNOME 自定义快捷键 `Alt+Z` 可以触发截图；
- [ ] Mutter ScreenCast 可以获取无快门声画面；
- [ ] 截图完成后显示冻结画面；
- [ ] 可以用鼠标拖出矩形选区；
- [ ] 选区大小与最终 PNG 内容一致；
- [ ] 保存按钮可以选择路径并生成 PNG；
- [ ] 复制按钮可以粘贴到图片编辑器或文件管理器；
- [ ] `Esc` 可以取消并关闭窗口；
- [ ] 未完成选区时，工具栏隐藏；
- [ ] 工具栏根据选区上下空间自动定位；
- [ ] 快捷键设置页可以展示当前快捷键、删除快捷键并录制新快捷键；
- [ ] 全流程不需要 root 权限。

### MVP1 暂不验收

- [ ] X11；
- [ ] 多显示器；
- [ ] 滚动截图；
- [ ] 截图贴图；
- [ ] 标注工具（MVP2 已实现矩形、箭头和文字标注）；
- [ ] OCR；
- [ ] 录屏；
- [ ] 截图历史；
- [x] 普通启动只显示托盘图标，不显示主应用窗口。

## 12. 实现顺序

1. 用静态 PNG 完成 Flutter 框选页面；
2. 添加选区裁剪和坐标缩放处理；
3. 添加保存路径选择和 PNG 保存；
4. 创建 Rust cdylib 并接入 Dart FFI；
5. 接入 Mutter ScreenCast + PipeWire 无快门声截图；
6. 接入 Wayland 图片剪贴板；
7. 支持 `--capture` 启动参数；
8. 配置 GNOME `Alt+Z`；
9. 完成真实环境验收。

## 13. 明确不做的事情

MVP 不实现以下内容：

- 不复制 Reticle 的 Swift 代码；
- 不引入 Flutter Web 或移动端适配；
- 不实现完整的 Snipaste；
- 不实现图片编辑器；
- 不实现自定义全局热键管理器；
- 不为了兼容所有 Linux 桌面环境提前增加抽象；
- 不将截图逻辑散落在 Flutter Widget 中。

一句话目标：**先在 GNOME Wayland 上稳定完成“Alt+Z → 无快门声框选 → 保存/复制”闭环。**
