# Rust native layer

Easy Shot 的 Linux 原生层已经接入 Flutter Linux 构建流程，生成：

```text
libeasy_shot_native.so
```

## 当前能力

- 通过 Mutter `org.gnome.Mutter.ScreenCast` 创建主显示器 PipeWire 流；
- 使用 GStreamer `pipewiresrc → videoconvert → pngenc` 获取无快门声单帧 PNG；
- 使用 `wl-copy --type image/png` 写入 GNOME Wayland 图片剪贴板；
- 通过 C ABI 暴露给 Dart FFI，并统一返回可读错误信息；
- 采集超时、Mutter/GStreamer 不可用时返回错误，不回退到会播放快门声的 Screenshot Portal。

## 构建

```bash
cd rust
cargo fmt --check
cargo check
cargo build --release
```

Flutter 的 `linux/CMakeLists.txt` 会在构建应用时自动执行 release 构建，并将动态库安装到：

```text
build/linux/x64/<mode>/bundle/lib/libeasy_shot_native.so
```

## C ABI

- `easy_shot_capture_screen`
- `easy_shot_copy_png_to_clipboard`
- `easy_shot_last_error`
- `easy_shot_remove_file`

Dart 封装位于 `lib/native/native_bridge.dart`。

## 当前环境依赖

MVP 目标是 GNOME + Wayland，需要：

```text
Mutter ScreenCast
GStreamer + pipewire-gstreamer + png 插件
wl-copy
```

本机已验证截图和图片剪贴板均可用。后续若要兼容没有 `wl-copy` 的发行版，再增加 native Wayland/GTK clipboard 后端。
