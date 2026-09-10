# Rust native layer

Hax Shot 的原生层按平台拆成两个后端，对外只暴露一份 C ABI：

```text
rust/src/lib.rs     C ABI、错误状态、临时文件路径
rust/src/linux.rs   Mutter ScreenCast + GStreamer + wl-copy
rust/src/macos.rs   CoreGraphics + ImageIO + NSPasteboard + Carbon 全局快捷键
```

生成：

```text
Linux: libhax_shot_native.so
macOS: libhax_shot_native.dylib
```

## 当前能力

- 截图：抓取目标显示器一帧并写成临时 PNG；
- 目标显示器：`--display <id>` 参数（托盘宿主在触发时写入）→ 光标所在显示器 → 主显示器；
- 剪贴板：写入图片剪贴板（Linux `wl-copy --type image/png`，macOS `NSPasteboard`）；
- 快捷键：macOS 注册全局热键并直接启动 `--capture` 子进程；
- 通过 C ABI 暴露给 Dart FFI，并统一返回可读错误信息。

平台实现提供同名函数：`capture_screen_impl` / `copy_png_impl` /
`register_capture_hotkey_impl` / `cursor_display_impl`，`lib.rs` 负责分发和错误处理。

## Linux 实现

- 通过 Mutter `org.gnome.Mutter.ScreenCast` 创建主显示器 PipeWire 流；
- 使用 GStreamer `pipewiresrc → videoconvert → pngenc` 获取无快门声单帧 PNG；
- 使用 `wl-copy --type image/png` 写入 GNOME Wayland 图片剪贴板；
- 快捷键交给 GNOME gsettings，`register_capture_hotkey_impl` 返回“不支持”错误；
- 采集超时、Mutter/GStreamer 不可用时返回错误，不回退到会播放快门声的 Screenshot Portal。

## macOS 实现

- `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 处理 TCC 屏幕录制权限；
- 用 `CGGetDisplaysWithPoint` 找到光标所在显示器，供托盘宿主和 `target_display()` 决定抓哪块屏；
- `CGDisplayCreateImage` 抓该显示器物理像素，ImageIO 直接编码 PNG；
- `NSPasteboard` 写 `public.png`（必须在主线程调用）；
- `global-hotkey`（Carbon `RegisterEventHotKey`）注册全局热键，触发时启动 `--capture` 子进程
  并带上 `--display <光标所在显示器>`；
- 绑定字符串与 Linux 共用 `<Super><Shift>z` 这种格式。

显示器选择规则必须和 `macos/Runner/CaptureDisplay.swift` 一致，详见
[开发指南 6.9](../docs/development-guide.md#69-多显示器)。

## 构建

```bash
cd rust
cargo fmt --check
cargo check
cargo test
cargo build --release
```

Flutter 构建流程会自动调用 cargo：

- Linux：`linux/CMakeLists.txt` 执行 `cargo build --release`，把 `.so` 安装到 `bundle/lib/`；
- macOS：`scripts/build_macos_rust.sh` 由 Xcode 脚本阶段调用，把 `.dylib` 复制到
  `Contents/Frameworks/`（Debug 用 dev profile，Release 用 release profile）。

## C ABI

- `hax_shot_capture_screen`
- `hax_shot_copy_png_to_clipboard`
- `hax_shot_register_capture_hotkey`
- `hax_shot_cursor_display`
- `hax_shot_last_error`
- `hax_shot_native_version`

Dart 封装位于 `lib/native/native_bridge.dart`。

## 当前环境依赖

Linux（GNOME + Wayland）：

```text
Mutter ScreenCast
GStreamer + pipewire-gstreamer + png 插件
wl-copy
```

macOS：只需要 Xcode 命令行工具，其余使用系统框架。

本机已验证 Linux 的截图和图片剪贴板可用；macOS 的截图路径需要用户在系统设置里授予
屏幕录制权限。
