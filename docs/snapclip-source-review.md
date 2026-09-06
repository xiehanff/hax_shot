# snapclip 与 GNOME 原生截图实现阅读报告

## 1. 为什么不能继续调用 Screenshot Portal

Easy Shot 原先通过 `org.freedesktop.portal.Screenshot` 请求整屏 PNG。这个接口适合普通应用获取授权后的截图，但在 GNOME Wayland 下会经过 Mutter 的截图路径，可能出现截图闪光和相机声音。

用户体验上，快捷键触发后先听到声音、再看到框选界面，会让人误以为工具已经自动保存了一张整屏截图。这个问题不是 Flutter 加载速度造成的，而是截图后端选择造成的。

## 2. GNOME 原生截图的关键顺序

GNOME Shell 的 `js/ui/screenshot.js` 在打开截图 UI 时先调用 Shell 内部的：

```text
Shell.Screenshot.screenshot_stage_to_content()
```

它直接从 Mutter 合成器得到一帧 GPU 内容，作为冻结背景放到截图 UI 下方；用户拖动选区后，只对这张缓存帧做裁剪。截图 UI 本身是 Shell 的全屏 actor，外层绘制黑色半透明遮罩，选区区域再显示原始冻结画面。

因此关键不是“先显示一个窗口再调用截图”，而是：

1. 先获取一帧不会触发截图快门的合成器画面；
2. 再展示全屏冻结画面和黑色遮罩；
3. 框选时不再重新抓屏；
4. 最终只裁剪缓存帧。

## 3. snapclip 的外部应用方案

本地参考仓库：`references/snapclip`。

它不能调用 GNOME Shell 的内部 `Shell.Screenshot` 对象，因此使用 Mutter 对外暴露的 ScreenCast D-Bus 接口：

```text
org.gnome.Mutter.ScreenCast
  CreateSession
  Session.RecordMonitor(connector, {cursor-mode: 0})
  Session.Start
  Stream.PipeWireStreamAdded → node id
```

然后用 GStreamer 管线取一帧：

```text
pipewiresrc num-buffers=1
  → videoconvert
  → pngenc
  → filesink
```

ScreenCast 是屏幕录制/共享通道，不是 Screenshot 通道，因此不会播放 GNOME 截图快门动画。snapclip 还通过 `org.gnome.Mutter.DisplayConfig.GetCurrentState` 找到主显示器 connector，保证录制的显示器与全屏 overlay 对应。

## 4. Easy Shot 的落地决策

Easy Shot 采用与 snapclip 相同的 ScreenCast 思路，但把实现放进 Rust：

- `zbus`：创建和停止 Mutter ScreenCast session；
- `gstreamer`：连接 `pipewiresrc`，输出单帧 PNG；
- Flutter `CapturePage`：等待 Rust 返回冻结帧后才显示全屏窗口；
- Flutter 只裁剪已缓存的 PNG，不在框选结束后再次截图；
- ScreenCast/GStreamer 不可用时直接提示错误，不偷偷回退到 Screenshot Portal。

这样可以同时满足：

- 快捷键触发后出现全屏黑色半透明框选层；
- 框选背景是触发瞬间的冻结画面；
- 没有 Portal 截图导致的整屏截图声音；
- 选区边框和工具栏不会写进最终 PNG。

## 5. 与参考实现的差异

| 项目 | snapclip | Easy Shot |
|---|---|---|
| UI | GTK4/Cairo | Flutter CustomPainter |
| ScreenCast | Python GObject D-Bus | Rust `zbus` |
| 单帧编码 | GStreamer Python binding | Rust GStreamer binding |
| 剪贴板 | `wl-copy` | `wl-copy` |
| 目标显示器 | 主显示器 | 主显示器，MVP 单显示器 |
| 失败回退 | 可选 `--allow-flash` | 不回退，避免再次出现快门声 |

## 6. 系统依赖

Fedora 至少需要：

```text
gstreamer1-devel
gstreamer1-plugins-base-devel
pipewire-devel
pipewire-gstreamer
gstreamer1-plugins-good
wl-clipboard
```

运行时还必须存在 `pipewiresrc` 和 `pngenc`：

```bash
gst-inspect-1.0 pipewiresrc
gst-inspect-1.0 pngenc
```

一句话总结：**GNOME 原生体验的核心是先缓存 Mutter 合成器的一帧，再显示冻结遮罩；Easy Shot 用 Mutter ScreenCast + PipeWire 在外部应用中复现这一顺序。**
