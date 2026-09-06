# Hax Shot

Hax Shot 是一个面向 **Fedora GNOME + Wayland** 的 tray-only 截图工具：按下快捷键后，先由 Mutter ScreenCast 获取无快门声的冻结画面，再在 Flutter 中框选，最后保存 PNG 或复制到图片剪贴板。

## 功能

- `Alt+Z` 触发全屏框选；
- Mutter ScreenCast + PipeWire 获取冻结画面，不使用 Screenshot Portal 快门路径；
- 鼠标拖拽矩形框选；
- 保存选区为 PNG；
- 使用 `wl-copy` 复制 PNG 到 Wayland 图片剪贴板；
- `Esc` 取消；
- GNOME 托盘菜单：立即截屏、修改快捷键、退出；
- 快捷键设置支持查看、删除和录制新的组合键。

当前 MVP 暂不包含标注绘制、贴图、OCR、历史和录屏。

## 支持范围

当前只保证：

- Fedora GNOME + Wayland；
- 主显示器；
- GNOME AppIndicator 扩展。

不保证 X11、KDE、wlroots、多显示器和其他桌面环境。

## 从源码运行

项目通过 FVM 固定 Flutter SDK 版本，版本配置位于 `.fvmrc`：

```text
Flutter 3.44.8
Dart 3.12.2
```

首次准备环境：

```bash
fvm install
fvm flutter --version
```

### 系统依赖

```text
Rust/Cargo
GTK 3 开发包
libayatana-appindicator-gtk3-devel
GStreamer、pipewire-gstreamer、pngenc 插件
PipeWire
wl-copy / wl-paste
```

### 构建和启动

```bash
fvm flutter pub get
fvm flutter run -d linux
```

直接触发一次截图：

```bash
fvm flutter run -d linux -- --capture
```

构建 Release：

```bash
fvm flutter build linux --release
```

构建产物为：

```text
build/linux/x64/release/bundle/hax_shot
build/linux/x64/release/bundle/lib/libhax_shot_native.so
```

## 安装 GNOME 快捷键

先构建 Release，再执行：

```bash
./scripts/install-gnome-shortcut.sh
```

脚本会注册：

```text
Alt+Z → hax_shot --capture
```

并安装应用入口：

```text
~/.local/share/applications/com.github.xiehanff.hax_shot.desktop
```

## 实现概览

- Flutter：托盘、设置页、截图预览、框选和工具条；
- Rust：Mutter ScreenCast/PipeWire 单帧截图、PNG 处理和 Wayland 图片剪贴板；
- Dart FFI：调用 `libhax_shot_native.so` 的 C ABI；
- GNOME GSettings：负责 Wayland 下的全局快捷键。

## 文档

- [MVP 方案](./mvp.md)
- [源码阅读索引](./docs/README.md)
- [当前实现与开发指南](./docs/development-guide.md)
- [图标、Dock 和托盘](./docs/icon-and-tray.md)
- [参考结论](./docs/reference-decisions.md)
- [许可证与第三方声明](./THIRD_PARTY_NOTICES.md)

## 许可证

Hax Shot 自有源代码和原创图标采用 [MIT License](./LICENSE)。第三方依赖、GNOME/GStreamer/PipeWire 组件和参考仓库分别遵循各自许可证，详见 [第三方声明](./THIRD_PARTY_NOTICES.md)。
