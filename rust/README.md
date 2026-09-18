# Rust native layer

HaxShot 的原生层按平台拆成三个后端，对外只暴露一份 C ABI：

```text
rust/src/lib.rs     C ABI、错误状态、临时文件路径、跨平台 PNG 编码
rust/src/linux.rs   Mutter ScreenCast + GStreamer + wl-copy
rust/src/macos.rs   CoreGraphics + ImageIO + NSPasteboard
rust/src/windows.rs GDI 抓屏 + 显示器枚举（Phase 1 只有 placeholder）
```

生成：

```text
Linux:   libhax_shot_native.so
macOS:   libhax_shot_native.dylib
Windows: hax_shot_native.dll（和 hax_shot.exe 同目录，由 windows/CMakeLists.txt 安装）
```

## 当前能力

- 截图：抓取目标显示器一帧并写成临时 PNG；
- 目标显示器：`--display <id>` 参数（托盘宿主在触发时写入）→ 光标所在显示器 → 主显示器；
- 剪贴板：写入图片剪贴板（Linux `wl-copy --type image/png`，macOS `NSPasteboard`）；
- 快捷键：**不经过 Rust**。macOS 由宿主进程原生侧的 `ShortcutBridge`（Carbon `RegisterEventHotKey`）注册、Dart 侧 `MacosShortcutService` 管状态，触发时再启动 `--capture` 子进程；
- 通过 C ABI 暴露给 Dart FFI，并统一返回可读错误信息。

平台实现提供同名函数：`capture_screen_impl` / `copy_png_impl` / `cursor_display_impl` /
`screen_capture_authorized_impl` / `request_screen_capture_access_impl`，`lib.rs` 负责分发和错误处理。

## Linux 实现

- 通过 Mutter `org.gnome.Mutter.ScreenCast` 创建主显示器 PipeWire 流；
- 使用 GStreamer `pipewiresrc → videoconvert → pngenc` 获取无快门声单帧 PNG；
- 使用 `wl-copy --type image/png` 写入 GNOME Wayland 图片剪贴板；
- 快捷键不经过原生层：GNOME 自己维护 gsettings 里的自定义快捷键（值为 `hax_shot --capture`）；
- 采集超时、Mutter/GStreamer 不可用时返回错误，不回退到会播放快门声的 Screenshot Portal。

## macOS 实现

- `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 处理 TCC 屏幕录制权限；
- 用 `CGGetDisplaysWithPoint` 找到光标所在显示器，供托盘宿主和 `target_display()` 决定抓哪块屏；
- `CGDisplayCreateImage` 抓该显示器物理像素，ImageIO 直接编码 PNG；
- `NSPasteboard` 写 `public.png`（必须在主线程调用）；

全局快捷键由宿主进程注册（macOS：`macos/Runner/ShortcutBridge.swift` 直接调 Carbon
`RegisterEventHotKey`；Linux：GNOME gsettings），Rust 不参与；绑定字符串与 Linux 共用
`<Super><Shift>z` 这种格式。

显示器选择规则只在 Rust 实现一次（`rust/src/macos.rs` 的 `resolve_target_display()`）：
Swift 侧 `macos/Runner/CaptureDisplay.swift` 通过 `dlopen` 调 `hax_shot_target_display`
拿同一块屏，不再重复实现规则。详见
[开发指南 6.9](../docs/development-guide.md#69-多显示器)。

## Windows 实现（进行中）

Phase 1 只提供 placeholder：`capture_screen_impl` / `copy_png_impl` 返回可读的
"not implemented yet"，`cursor_display_impl` 返回 `0`（= 未指定，不是主屏），
`screen_capture_authorized_impl` / `request_screen_capture_access_impl` 返回 `1`
（Windows 没有 macOS 那种屏幕录制授权流程）。placeholder 不 `panic` / `unwrap`，也不返回
伪造的成功。

Windows 专用的两个导出（`#[cfg(target_os = "windows")]`）共用同一个
`#[repr(C)] HaxShotTargetMonitor`（`valid` / `error_code` / `display_id` / rcMonitor /
`dpi` / `generation`）：

- `hax_shot_target_monitor(requested, out)`：只查询当前拓扑（诊断 / 预检用）；
- `hax_shot_last_capture_target(out)`：读**本进程最近一次成功抓屏冻结**的元数据，摆浮层必须用它。

错误码 `0 = ok`、`1 = NO_TARGET`、…、`7 = NOT_IMPLEMENTED`；可读文本仍走 `hax_shot_last_error`。

选屏规则与 macOS 一致（`--display` → 光标所在显示器 → 主显示器；`0` 表示未指定）；
显示器 id 是 `MONITORINFOEXW.szDevice` 的 FNV-1a 32 位（offset basis `0x811C9DC5`、
prime `0x01000193`，逐 UTF-16 code unit 取低字节，不含终止 NUL）。规则只在 Rust 实现一次：
C++ / Dart **不允许**自己调 `EnumDisplayMonitors` / `GetMonitorInfoW`，也不允许重算 hash。

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
  `Contents/Frameworks/`（Debug 用 dev profile，Release 用 release profile）；
- Windows：`windows/CMakeLists.txt` 执行 `cargo build --release --target-dir rust/target`，
  把 `hax_shot_native.dll` 安装到当前 Flutter 配置的 bundle 目录（exe 旁）。
  三种 Flutter 配置都用这一份 release DLL；改这里的路径必须和 cargo 的实际输出目录同步。

## C ABI

- `hax_shot_screen_capture_authorized`
- `hax_shot_request_screen_capture_access`
- `hax_shot_cursor_display`
- `hax_shot_capture_screen`
- `hax_shot_copy_png_to_clipboard`
- `hax_shot_png_buffer_size`
- `hax_shot_encode_png`
- `hax_shot_last_error`
- `hax_shot_target_display`（macOS only）：按抓屏用的同一份规则返回目标显示器的
  `CGDirectDisplayID`，给 macOS Runner 的 Swift 把冻结画面浮层摆到同一块屏上。
- `hax_shot_target_monitor`（Windows only）：查询当前拓扑下的目标显示器元数据；
- `hax_shot_last_capture_target`（Windows only）：读本进程冻结的目标元数据。

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
