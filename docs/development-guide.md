# Hax Shot 当前实现与后续开发指南

> 这份文档记录的是**当前代码已经实现的行为**，不是最初的设计草案。后续 Agent 开始改 UI、截图流程或 Linux 集成前，应先读本文件，再读 [`reference-decisions.md`](./reference-decisions.md) 和 [`icon-and-tray.md`](./icon-and-tray.md)。

## 0. 开发工具链

项目使用 FVM 固定 Flutter SDK：

```text
Flutter 3.44.8
Dart 3.12.2
```

首次准备或切换 SDK：

```bash
fvm install
fvm use 3.44.8
fvm flutter --version
```

后续所有 Flutter 命令都使用 `fvm flutter`，不要直接调用系统 Flutter。

## 1. 先记住产品边界

Hax Shot 是一个 **tray-only** 应用：普通进程没有主应用窗口，只有 GNOME 托盘图标和托盘菜单。

托盘菜单目前只有：

```text
立即截屏
修改快捷键
退出
```

“修改快捷键”会临时显示一个设置窗口，而不是打开外部控制中心。设置窗口展示当前 GNOME 快捷键，右侧 `×` 清空快捷键，点击“录制新的快捷键”后聚焦键盘录制区域；按下带修饰键的组合键后立即写回 GNOME GSettings，按 `Esc` 取消录制。设置页还提供基于 XDG autostart 的“开机自启动”开关。关闭设置窗口后，宿主仍回到纯托盘状态。

截图流程是：

```text
Alt+Z / 托盘“立即截屏”
    ↓
启动一个新的 hax_shot --capture 进程
    ↓
窗口保持隐藏，Rust 通过 Mutter ScreenCast + PipeWire 获取一帧冻结画面
    ↓
显示 Flutter 全屏、置顶、不可进入任务栏的框选界面
    ↓
拖拽选区
    ↓
同一张冻结图裁剪
    ├── 保存 PNG
    ├── 复制 image/png 到 Wayland 剪贴板
    ├── 点击矩形/箭头工具后，在截图选区内继续拖拽绘制标注
    ├── 点击文字工具后，在截图选区内单击并输入文字，再拖动四角缩放字号
    ├── 保存/复制带标注的最终 PNG
    └── Esc 取消
```

这里有一个必须保持的认知：**`--capture` 进程不是先显示黑窗口再截图，而是先在隐藏窗口状态下获取冻结帧，再显示框选 UI。** 如果顺序反过来，ScreenCast 会把自己的黑色遮罩或 Flutter UI 捕获进去。

## 2. 关键入口和职责

| 文件 | 职责 | 修改时的注意事项 |
|---|---|---|
| `lib/main.dart` | 解析 `--capture`，配置窗口 | `skipTaskbar` 必须保持为 `true`；捕获进程必须先隐藏 |
| `lib/app.dart` | tray-only 宿主、快捷键设置页、菜单、启动子进程 | 不要重新添加主应用窗口；设置页是按需显示的临时窗口；菜单截图通过 `Platform.resolvedExecutable --capture` 启动独立进程 |
| `lib/features/settings/shortcut_settings_page.dart` | 快捷键录制、开机自启动开关 | 快捷键通过 `gsettings` 写入，启动项通过 `AutostartService` 写入当前用户 XDG 配置 |
| `lib/features/capture/capture_page.dart` | 冻结图加载、框选、保存、复制 | `_capture()` 完成前不要显示捕获窗口；保存/复制使用同一份裁剪逻辑 |
| `lib/features/capture/capture_toolbar.dart` | 磨砂玻璃工具条、HugeIcons 图标和标注工具 | 保持全圆角、纯白图标、BackdropFilter；矩形/箭头/文字工具通过 callback 切换，颜色由 CapturePage 持有并用于预览和最终 PNG |
| `lib/features/capture/screenshot_canvas.dart` | 图片适配、遮罩、选区和矩形/箭头/文字绘制、point→pixel 映射 | `ScreenshotLayout` 的坐标是 Flutter logical pixels，最终裁剪和标注导出是物理像素 |
| `lib/native/native_bridge.dart` | Dart FFI 封装 | 不在这里执行 DBus 或 `wl-copy`，这些都属于 Rust 原生层 |
| `rust/src/lib.rs` | Mutter ScreenCast、GStreamer、`wl-copy`、C ABI | 不要悄悄回退到 Screenshot Portal，否则会重新出现 GNOME 快门声 |
| `linux/runner/my_application.cc` | GTK 窗口、应用 ID、开发桌面项 | Dart 负责显示/隐藏；不要恢复旧的 first-frame 自动显示逻辑 |
| `linux/CMakeLists.txt` | Flutter bundle、Rust 库、desktop 文件和 hicolor 图标安装 | Rust 动态库和系统 GStreamer 插件是两套不同依赖 |
| `scripts/install-gnome-shortcut.sh` | 安装 `Alt+Z` 和用户 desktop/icon | 改快捷键或图标后要重新运行此脚本 |

## 3. 两个进程模型

### 3.1 普通托盘宿主

执行：

```bash
fvm flutter run -d linux
```

或直接运行 bundle：

```bash
build/linux/x64/release/bundle/hax_shot
```

这个进程：

- `skipTaskbar: true`；
- 不显示窗口；
- 初始化 `tray_manager`；
- 通过 AppIndicator 注册 GNOME 托盘图标；
- 菜单中的“立即截屏”启动独立的 `--capture` 子进程；
- 菜单中的“修改快捷键”显示 `ShortcutSettingsPage`；
- 设置页通过 `gsettings` 读取 `binding`，删除时写入空字符串，录制成功后同时更新 `name`、`command`、`binding`；
- 托盘菜单“退出”会先取消窗口拦截、销毁托盘，再强制结束 Dart/GTK 进程；仅调用 `windowManager.close()` 不足以结束隐藏的 GtkApplication 事件循环。
- 普通进程退出时才销毁托盘图标。

因此调 UI 时如果只运行普通命令，看不到窗口是正常的。要看框选 UI，可以按 `Alt+Z`，或运行：

```bash
fvm flutter run -d linux -- --capture
```

### 3.2 短生命周期捕获进程

`--capture` 进程不初始化托盘页面，而是进入 `CapturePage`：

1. GTK/Flutter 窗口创建但保持隐藏；
2. `CapturePage` 首帧后调用 `NativeBridge.captureScreen()`；
3. Rust 完成 ScreenCast + GStreamer 单帧 PNG；
4. Dart 解码 PNG；
5. 窗口才 `show()`、`focus()`；
6. `Esc`、保存成功或复制成功后关闭进程。

`linux/runner/my_application.cc` 中已经移除了旧的 `first-frame` 自动 `gtk_widget_show()`。这是故意的：如果 native first-frame 回调再次显示窗口，捕获时机就会被破坏。

## 4. 无快门声截图管线

### 4.1 为什么不用 Screenshot Portal

`org.freedesktop.portal.Screenshot` 是标准授权接口，但 GNOME Wayland 的 Screenshot 路径可能播放截图闪光/相机声音。它适合普通“拍一张屏幕”的工具，不适合本项目的“先冻结、再框选”体验。

GNOME Shell 自己的截图 UI 使用 Mutter 内部的 `screenshot_stage_to_content()` 获取合成器内容，再在 Shell actor 上绘制遮罩。外部应用无法直接调用这个 Shell 内部对象，所以 Hax Shot 使用 Mutter 对外的 ScreenCast D-Bus 接口复现同样的顺序。

### 4.2 Rust 的实际调用顺序

`rust/src/lib.rs` 中的顺序不能随意调整：

```text
org.gnome.Mutter.DisplayConfig.GetCurrentState
    → 找到 primary monitor 的 connector

org.gnome.Mutter.ScreenCast.CreateSession
    → Session.RecordMonitor(connector, cursor-mode=0)
    → 监听 Stream.PipeWireStreamAdded
    → Session.Start
    → 得到 PipeWire node id

GStreamer:
pipewiresrc(path=node id, num-buffers=1)
    → videoconvert
    → pngenc
    → filesink(/tmp/hax-shot-*.png)

Session.Stop
    → 把 PNG 路径返回给 Dart
```

`cursor-mode=0` 表示不把鼠标光标放进冻结图，Flutter 只负责显示当前鼠标位置和选区边框。

### 4.3 为什么不能直接使用 `grim` 或 `scrot`

- `grim/slurp` 依赖 wlroots 的 `wlr-screencopy`，Mutter 通常不提供；
- `scrot` 是 X11 路径；
- GNOME Shell 的 Screenshot D-Bus 接口可能对普通应用返回 `AccessDenied`；
- 直接使用 Screenshot Portal 会重新触发本项目要避免的快门效果。

因此当前实现明确限定：**GNOME + Wayland + Mutter ScreenCast + GStreamer PipeWire**。

## 5. Rust/系统依赖

### Fedora 开发依赖

至少需要：

```bash
sudo dnf install -y \
  gstreamer1-devel \
  gstreamer1-plugins-base-devel \
  pipewire-devel \
  pipewire-gstreamer \
  gstreamer1-plugins-good \
  wl-clipboard \
  libayatana-appindicator-gtk3-devel
```

检查运行时插件：

```bash
gst-inspect-1.0 pipewiresrc
gst-inspect-1.0 pngenc
```

常见误区：Rust 的 `cargo build` 只会编译 Rust binding，不会把系统的 GStreamer/PipeWire 插件打包进 Flutter bundle。目标机器仍必须安装 `pipewiresrc`、`pngenc` 和 PipeWire 服务。

### Rust 构建

```bash
cd rust
source "$HOME/.cargo/env"
cargo fmt --check
cargo check
cargo test
cargo build --release
```

Flutter 的 CMake 会自动执行：

```text
cargo build --manifest-path rust/Cargo.toml --release
```

即使 Flutter 是 debug 构建，Rust 库也放在 `rust/target/release/`，最终复制到：

```text
build/linux/x64/<mode>/bundle/lib/libhax_shot_native.so
```

### FFI 和临时文件

`hax_shot_capture_screen` 返回 NUL 结尾的临时 PNG 路径，而不是把整张图片通过 FFI 复制回 Dart。Dart 读取并解码后会尝试删除文件；删除失败时只保留临时文件，不影响截图结果。

`hax_shot_copy_png_to_clipboard` 通过：

```bash
wl-copy --type image/png
```

写入图片剪贴板。之前尝试 `wl-clipboard-rs` 时，GNOME compositor 不支持所需的 data-control 协议，因此不要在没有验证的情况下替换这条路径。

## 6. 选区坐标规则

Flutter 侧使用：

```text
原点：左上角
方向：x 向右，y 向下
单位：logical pixel
```

PNG 使用：

```text
原点：左上角
方向：x 向右，y 向下
单位：physical pixel
```

`ScreenshotLayout` 负责：

1. 将完整 PNG 按比例 fit 到 Flutter viewport；
2. 将鼠标位置 clamp 到 `imageRect`；
3. 将选区从 logical 坐标转换成 PNG pixel rect；
4. 使用 floor/ceil 保证边界覆盖；
5. 在 `Canvas.drawImageRect` 中生成最终 PNG。

不要在 Dart 和 Rust 两边重复缩放或翻转 Y 轴。新增标注、裁剪或导出功能时，必须复用 `ScreenshotLayout.toPixelRect()` 的规则。

当前 MVP 只保证主显示器/单显示器场景。`DisplayConfig` 只选择 primary connector，不能把多显示器偏移直接当成单屏坐标使用。

## 7. 快捷键设置、录制与 desktop 文件

### 默认快捷键

安装脚本设置：

```text
gsettings binding = <Alt>z
```

快捷键不是 Flutter 内部注册的。Wayland 下普通应用不能可靠地伪造任意全局热键，所以由 GNOME 自定义快捷键执行：

```text
hax_shot --capture
```

### `Exec` 和 desktop ID 的区别

脚本会写入：

```text
~/.local/share/applications/com.github.xiehanff.hax_shot.desktop
```

这个文件使用：

```text
Exec=/.../hax_shot
Icon=com.github.xiehanff.hax_shot
NoDisplay=false
StartupWMClass=com.github.xiehanff.hax_shot
```

注意：`Exec` 是普通 tray 宿主，不是 `--capture`；真正的快捷键命令由 gsettings 单独保存为 `hax_shot --capture`。`NoDisplay=false` 让 Hax Shot 出现在 GNOME 应用列表中；从应用列表启动后仍只驻留托盘，不显示主窗口。

桌面文件名、Wayland app ID、`StartupWMClass`、图标名必须保持一致：

```text
com.github.xiehanff.hax_shot
com.github.xiehanff.hax_shot.desktop
com.github.xiehanff.hax_shot.png
```

以前 Dock 显示 Flutter 默认图标，核心风险就是这些标识不一致、旧 desktop 文件残留或图标缓存没有刷新。

### 设置页的快捷键录制规则

实现文件：`lib/features/settings/shortcut_settings_page.dart`。

当前规则参考 Cliper 的以下实现：

```text
/home/han/Documents/github/cliper/lib/presentation/widgets/header/header_widget.dart
/home/han/Documents/github/cliper/lib/application/controllers/settings_handler.dart
```

当前规则与 Cliper 的录制逻辑保持一致：

- 只处理 `KeyDownEvent`；
- 单独按下 Ctrl/Alt/Shift/Super 不提交；
- 必须包含至少一个修饰键和一个主体按键；
- `Esc` 取消录制；
- 组合键转成 GNOME 格式，例如 `Alt+Z` → `<Alt>z`、`Ctrl+Shift+4` → `<Control><Shift>4`；
- 新快捷键保存到固定 schema，并确保 `custom-keybindings` 数组包含 `hax-shot` 路径；
- 删除只清空 `binding`，保留 relocatable schema，方便下一次录制直接恢复；
- 设置页关闭/隐藏后不销毁托盘宿主。

这里有一个容易踩的坑：`gsettings get` 返回的是带引号的 GVariant 文本，例如 `'<Alt>z'`，不能直接把整行当作显示文本；代码需要先去除 GVariant 引号，再转换为 `Alt+Z`。

### 开发模式的额外行为

debug 构建中 `my_application.cc` 会把 bundle 内的图标复制到：

```text
~/.local/share/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png
```

并动态生成一个带绝对路径的开发 desktop 文件，方便 `fvm flutter run` 的窗口被 GNOME 识别。这个文件可能把 release desktop 的 `Exec` 临时改成 debug 路径。

所以在验证 GNOME 快捷键前，建议重新执行：

```bash
./scripts/install-gnome-shortcut.sh
```

如果项目目录移动过、build 目录清理过或 release 路径变化，也必须重新执行脚本。

## 8. 截图选区后的工具栏定位

实现文件：

```text
lib/features/capture/selection_toolbar_placement.dart
lib/features/capture/capture_page.dart
```

参考实现：

```text
/home/han/Documents/github/plume-pdf/lib/app/modules/home/views/widgets/pdf_page_area_selection_overlay.dart
/home/han/Documents/github/plume-pdf/lib/app/modules/home/views/widgets/selection_toolbar_placement.dart
```

工具栏不再固定在屏幕底部，而是参照 Plume PDF AI 框选工具栏的策略。**拖拽进行中不显示工具栏，只有 `onPanEnd` 确认有效选区后才显示**，这样定位算法拿到的是最终矩形，而不是不断变化的中间矩形。

1. 选区下方有足够空间时，放在选区下方；
2. 下方放不下、上方放得下时，放在选区上方；
3. 上下两侧都不足可用空间时，把工具栏放在选区中心；
4. 工具栏水平方向始终跟随选区中心，并在左右边缘做 clamp；因此左侧框选不会跑到屏幕中心，右侧框选也不会被截断；
5. 通过 `CustomSingleChildLayout` 获取真实工具栏尺寸，不能写死宽度，因为字体、按钮文字和主题可能改变组件宽度；同时必须在 `SingleChildLayoutDelegate.getConstraintsForChild` 中返回 `constraints.loosen()`，否则子工具栏会被施加全屏紧约束，既会跑到左上/左侧，也会让其背景遮住整张截图；
6. viewport 和 toolbar 都留 12px 边距，避免贴住屏幕边缘。

当前 `CaptureToolbar` 包含取消、保存、复制、截图框选、矩形标注、箭头标注、文字标注、颜色板（红/紫/黄/绿/橙）和 AI 预留控件。图标统一使用 `hugeicons` 的 `strokeRounded` 风格；矩形和箭头通过拖拽绘制，文字工具通过单击创建输入框，并可拖动四角缩放字号。颜色由 CapturePage 持有并用于预览和最终 PNG。拖拽中的临时矩形仍然绘制边框，但工具栏要等 `selectionCommitted` 在 `onPanEnd` 中变为 true 后才显示。开始下一次截图选区拖拽时立即清空旧标注。

已添加 `test/selection_toolbar_placement_test.dart` 覆盖顶部、底部、左右边缘、几乎占满屏幕，以及真实 `CustomSingleChildLayout` 尺寸约束。

## 9. 图标更换流程

当前图标源文件是项目原创的：

```text
assets/icons/hax_shot.svg
```

使用 ImageMagick 生成 Linux hicolor 图标组：

```bash
for size in 16 24 32 48 64 128 256 512; do
  magick -background none assets/icons/hax_shot.svg \
    -resize "${size}x${size}" -depth 8 \
    "linux/icons/hicolor/${size}x${size}/apps/com.github.xiehanff.hax_shot.png"
done
```

当前工程有两份用途不同的图标：

| 路径 | 用途 |
|---|---|
| `assets/icons/hax_shot.png` | Flutter `tray_manager` 和 Flutter 资源 |
| `linux/icons/hicolor/*/apps/com.github.xiehanff.hax_shot.png` | GNOME desktop/icon theme |
| `linux/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png` | GTK runner 的 `data/hax_shot_icon.png` 来源 |
| `linux/icons/hax_shot.png` | 256px 兼容副本，不是 hicolor 主来源 |

更换图标后必须同时完成：

```bash
fvm flutter build linux --release
./scripts/install-gnome-shortcut.sh
```

正在运行的托盘进程通常已经缓存了旧图标，必须退出并重新启动 Hax Shot；只替换 PNG 文件不一定会立即刷新已经显示的 AppIndicator 图标。

## 10. 调试和验证清单

### Dart/Flutter

```bash
fvm flutter analyze
fvm flutter test
fvm flutter build linux --debug
fvm flutter build linux --release
```

### Rust

```bash
cd rust
source "$HOME/.cargo/env"
cargo fmt --check
cargo check
cargo test
```

### desktop/icon

```bash
desktop-file-validate \
  packaging/hax_shot.desktop \
  build/linux/x64/release/bundle/share/applications/com.github.xiehanff.hax_shot.desktop \
  "$HOME/.local/share/applications/com.github.xiehanff.hax_shot.desktop"

sha256sum \
  assets/icons/hax_shot.png \
  linux/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png \
  build/linux/x64/release/bundle/data/hax_shot_icon.png
```

### 运行时检查

普通进程应该没有 Wayland toplevel，只保留托盘图标：

```bash
WAYLAND_DEBUG=1 build/linux/x64/debug/bundle/hax_shot
```

捕获进程应该在 Rust 返回 PNG 后才出现全屏 toplevel：

```bash
build/linux/x64/debug/bundle/hax_shot --capture
```

不要用宽泛的 `pkill -f 'fvm flutter run -d linux'` 清理进程，它可能误杀其他项目的 Flutter 调试会话。优先根据工作目录和 PID 判断，或者只使用：

```bash
pkill -x hax_shot
```

## 11. 已知限制和未完成项

- 仅支持 GNOME + Wayland；
- 仅支持 primary monitor，暂不处理多显示器和混合 DPI；
- 不支持 X11、KDE、wlroots compositor；
- ScreenCast 服务或 GStreamer 插件不可用时会失败，不使用有快门声的 Portal 兜底；
- 暂不捕获鼠标光标；
- 暂不支持 OCR、贴图、历史、录屏和滚动截图；
- 快捷键每次启动独立 `--capture` 进程，尚未实现多次触发的单实例锁；
- AppIndicator 依赖 GNOME Shell AppIndicator 扩展，Fedora 可能打印 deprecated warning，但当前功能正常；
- system GStreamer/PipeWire 依赖不会随 Rust `.so` 一起分发；
- 关闭或杀掉 tray 宿主后，GNOME 自定义快捷键仍可能指向旧的 release 路径，需要重新安装快捷键。

## 12. 给后续 Agent 的最短交接信息

如果任务是调整捕获 UI：只改 `lib/features/capture/`，保持 `_capture()` 完成后再 `windowManager.show()`。

如果任务是调整托盘：只改 `TrayHostPage`，不要添加主应用窗口；截图必须通过 `--capture` 子进程启动。

如果任务是调整截图后端：先阅读 `docs/snapclip-source-review.md`，保持 Mutter ScreenCast 的调用顺序，不要替换为 Screenshot Portal。

如果任务是调整图标/Dock 匹配：先检查 application ID、desktop 文件名、`Icon` 名称和 `StartupWMClass`，然后运行安装脚本并重启旧进程。

如果任务是增加跨平台支持：先明确不能把当前 Mutter/GStreamer 路径抽象成所有 Linux 桌面的通用方案；应新增后端并保留 GNOME backend。

一句话记忆：**先确定这是 tray 宿主还是 `--capture` 窗口，再修改对应层；不要让隐藏时序、desktop ID 或 ScreenCast 顺序被无意破坏。**
