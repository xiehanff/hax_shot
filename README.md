# Hax Shot

Hax Shot 是一个面向 **Fedora GNOME + Wayland** 的 tray-only 截图工具：按下快捷键后，先由 Mutter ScreenCast 获取无快门声的冻结画面，再在 Flutter 中框选，最后保存 PNG 或复制到图片剪贴板。

## 功能

- `Alt+Z` 触发全屏框选；
- Mutter ScreenCast + PipeWire 获取冻结画面，不使用 Screenshot Portal 快门路径；
- 鼠标拖拽矩形框选；
- 保存选区为 PNG；
- 使用 `wl-copy` 复制 PNG 到 Wayland 图片剪贴板；
- `Esc` 取消；
- GNOME 托盘菜单：立即截屏、设置、退出；
- 设置页统一管理快捷键和 GNOME 登录后自动启动；
- 框选后支持选择颜色绘制矩形标注；
- 框选后支持拖动绘制方向和长度可控的箭头标注；
- 支持文字标注，输入后可拖动文字框四角缩放字号、顶部抓手移动，并可删除或再次编辑当前文字框；
- AI 侧栏支持截图翻译、解释和深度理解；
- AI 支持图片拖拽/剪贴板输入、DeepSeek reasoning、Markdown 流式输出、停止生成和推荐追问。

当前暂不包含贴图、OCR、持久化会话和录屏。

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

- [源码阅读索引](./docs/README.md)
- [当前实现与开发指南](./docs/development-guide.md)
- [图标、Dock 和托盘](./docs/icon-and-tray.md)
- [参考结论](./docs/reference-decisions.md)
- [MVP2 功能说明](./docs/mvp2.md)
- [Linux 打包与分发](./docs/packaging.md)
- [CI 与 GitHub Release](./docs/ci-release.md)
- [许可证与第三方声明](./THIRD_PARTY_NOTICES.md)

## CI 与 GitHub Release

GitHub Actions 只在推送版本 tag 时运行打包流程，不会因为普通 `main` 分支 push 或手动运行 workflow 而发布 RPM：

```bash
git tag -a v1.3.0 -m "Release v1.3.0"
git push origin v1.3.0
```

tag 的版本号必须匹配 `pubspec.yaml` 中 `+` 前的版本号，例如 `1.3.0+1` 使用 `v1.3.0`。`+1` 会成为 Fedora RPM 的 Release 字段。构建通过后，RPM 会自动上传到对应的 GitHub Release 页面。

详细流程见 [CI 与 GitHub Release](./docs/ci-release.md)。

## 许可证

Hax Shot 源代码采用 [MIT License](./LICENSE)。当前应用图标来自外部 `.icns` 资源；第三方依赖、GNOME/GStreamer/PipeWire 组件和参考仓库分别遵循各自许可证，详见 [第三方声明](./THIRD_PARTY_NOTICES.md)。
