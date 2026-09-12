# Hax Shot

Hax Shot 是一个 **tray-only** 的桌面截图工具：按下全局快捷键后先获取冻结画面，再在 Flutter 中框选、标注，最后保存 PNG、复制到图片剪贴板或交给 AI 理解。

当前支持 Linux（Fedora GNOME + Wayland）和 macOS 两个平台，共用同一套 Flutter UI 和 Rust 原生接口：

```text
tray 宿主（常驻）
    ↓ 全局快捷键 / 托盘菜单
--capture 子进程
    ↓ 原生抓屏（隐藏窗口状态下）
冻结画面 + 框选 + 标注
    ├── 复制 PNG
    ├── 保存 PNG
    └── Ask AI
```

## 功能

- 全局快捷键触发全屏框选；
- 先抓冻结画面、再显示框选 UI，不会把自己的遮罩录进去；
- 鼠标拖拽矩形框选；
- 保存选区为 PNG；
- 复制 PNG 到系统图片剪贴板；
- `Esc` 取消；
- 托盘菜单：立即截屏、设置、退出；
- 设置页统一管理快捷键和开机自启动；
- 框选后支持选择颜色绘制矩形标注；
- 框选后支持拖动绘制方向和长度可控的箭头标注；
- 支持文字标注，输入后可拖动文字框四角缩放字号、顶部抓手移动，并可删除或再次编辑当前文字框；
- AI 侧栏支持截图翻译、解释和深度理解；
- AI 支持图片拖拽/剪贴板输入、DeepSeek reasoning、Markdown 流式输出、停止生成和推荐追问。

当前暂不包含贴图、OCR、持久化会话和录屏。

## 支持范围

Linux 当前只保证：

- Fedora GNOME + Wayland；
- 主显示器；
- GNOME AppIndicator 扩展。

不保证 X11、KDE、wlroots、多显示器和其他桌面环境。

macOS 当前只保证：

- 多显示器：按光标所在屏幕截图，浮层和截图始终是同一块屏；每块屏各自适配 Retina/非 Retina 缩放；
- 菜单栏（`LSUIElement`，没有 Dock 图标）；
- 首次截图需要在系统设置里授予“屏幕录制”权限。

Linux 目前仍只抓主显示器，原因见 [开发指南的多显示器说明](./docs/development-guide.md#69-多显示器)。

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

### Linux 系统依赖

```text
Rust/Cargo
GTK 3 开发包
libayatana-appindicator-gtk3-devel
GStreamer、pipewire-gstreamer、pngenc 插件
PipeWire
wl-copy / wl-paste
```

### Linux 构建和启动

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

### macOS 系统依赖

```text
Xcode（含命令行工具）
CocoaPods
Rust/Cargo
```

### macOS 构建和启动

```bash
fvm flutter pub get
fvm flutter run -d macos
fvm flutter build macos --release
```

构建产物为：

```text
build/macos/Build/Products/Release/hax_shot.app
```

macOS 常用脚本：

```bash
scripts/run_macos_debug.sh      # 构建 debug 并用 open 启动（调试期不要用 flutter run 授权，原因见文档）
scripts/build_macos_dmg.sh      # 打可分发的 DMG（自动签名/可选公证 + 逐项验收）
scripts/build_macos_dmg.sh --debug --install   # 本机联调用 debug DMG 并装到 /Applications
scripts/uninstall_macos_app.sh  # 卸载：应用、自启动项、授权记录、偏好设置（--dry-run 可先看）
```

macOS 首次启动会自动使用默认快捷键 `⌥⇧Z`（菜单栏图标可能被 Bartender 这类工具收进
隐藏区，所以默认就有一个不依赖图标的入口）；可以在托盘菜单“设置”里改。
第一次截图时不会直接弹全屏框选，而是先弹一个小窗口的授权引导：点“打开系统设置”勾选
Hax Shot，再点“我已授权，重新检查”即可（没授权时不会盖住整个屏幕）。

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

- Flutter：托盘、设置页、截图预览、框选和工具条，三个平台共用；
- Rust：平台后端 + 一份共用 C ABI；
  - Linux：Mutter ScreenCast/PipeWire 单帧截图、`wl-copy` 写图片剪贴板；
  - macOS：CoreGraphics/ImageIO 按目标显示器抓屏、`NSPasteboard` 写图片剪贴板、Carbon 全局快捷键；
- Dart FFI：调用 `libhax_shot_native.so` / `libhax_shot_native.dylib`；
- 快捷键：Linux 使用 GNOME GSettings，macOS 使用原生全局热键 + `~/Library/LaunchAgents` 自启动。

## 文档

- [源码阅读索引](./docs/README.md)
- [当前实现与开发指南](./docs/development-guide.md)（含 [macOS 平台适配](./docs/development-guide.md#6-macos-平台适配)）
- [Rust 原生层](./rust/README.md)
- [图标、Dock 和托盘](./docs/icon-and-tray.md)
- [参考结论](./docs/reference-decisions.md)
- [MVP2 功能说明](./docs/mvp2.md)
- [Linux 打包与分发](./docs/packaging.md)
- [macOS 打包与分发](./docs/macos-distribution.md)
- [CI 与 GitHub Release](./docs/ci-release.md)（tag 触发 DMG/DEB/RPM 构建与发布）
- [许可证与第三方声明](./THIRD_PARTY_NOTICES.md)

## CI 与 GitHub Release

GitHub Actions 只在推送版本 tag 时运行打包流程，不会因为普通 `main` 分支 push 或手动运行 workflow 而发布安装包：

```bash
git tag -a v1.3.0 -m "Release v1.3.0"
git push origin v1.3.0
```

tag 的版本号必须匹配 `pubspec.yaml` 中 `+` 前的版本号，例如 `1.3.0+1` 使用 `v1.3.0`。发布流程会构建三平台安装包（macOS arm64 DMG、Debian/Ubuntu DEB、Fedora RPM），全部上传到对应的 GitHub Release 页面；RPM 的 Release 字段和 DEB 的版本号取自 `+1`。普通 `main` push 上的 analyze/test 由 `verify.yml` 负责。

详细流程（含 macOS 签名/公证 secrets）见 [CI 与 GitHub Release](./docs/ci-release.md)。

## 许可证

Hax Shot 源代码采用 [MIT License](./LICENSE)。当前应用图标来自外部 `.icns` 资源；第三方依赖、GNOME/GStreamer/PipeWire 组件和参考仓库分别遵循各自许可证，详见 [第三方声明](./THIRD_PARTY_NOTICES.md)。
