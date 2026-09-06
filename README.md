# Easy Shot

Linux GNOME + Wayland 最小截图工具，使用 Flutter 实现 UI，Rust 实现截图和图片剪贴板能力。

## 当前功能

- `Alt+Z` 触发截图；
- 当前屏幕冻结画面；
- 鼠标拖拽矩形框选；
- 保存选区为 PNG；
- 复制选区到 Wayland 图片剪贴板；
- `Esc` 取消；
- 由 Proton Pass `.icns` 生成图标的 GNOME 托盘菜单；
- 常驻托盘，不提供主应用窗口；菜单包含立即截屏、快捷键设置和退出；
- 快捷键设置支持查看、删除和录制新的组合键。

当前 MVP 暂不包含标注、贴图、OCR、历史和录屏。

## 运行

```bash
cd /home/han/Documents/github/easy_shot
flutter run -d linux
```

直接触发一次截图：

```bash
flutter run -d linux -- --capture
```

## 构建

```bash
flutter build linux --release
```

Rust 动态库会由 `linux/CMakeLists.txt` 自动构建并放入 Flutter bundle：

```text
build/linux/x64/release/bundle/lib/libeasy_shot_native.so
```

## 安装 GNOME 快捷键

先构建 release，再执行：

```bash
./scripts/install-gnome-shortcut.sh
```

脚本会注册：

```text
Alt+Z → easy_shot --capture
```

并写入 `~/.local/share/applications/com.example.easy_shot.desktop`。

## 系统依赖

当前目标环境：GNOME + Wayland。

需要：

- Rust/Cargo；
- Mutter `ScreenCast`、GStreamer 的 `pipewiresrc`/`pngenc`；
- `wl-copy` / `wl-paste`；
- `libayatana-appindicator-gtk3-devel`（构建托盘插件）；
- GStreamer 开发包、`pipewire-gstreamer` 和 PNG 编码插件。

## 文档

- [MVP 方案](./mvp.md)
- [源码阅读索引](./docs/README.md)
- [参考结论](./docs/reference-decisions.md)
- [当前实现与开发指南](./docs/development-guide.md)
- [Reticle 源码报告](./docs/reticle-source-review.md)
- [SnapShotKit 源码报告](./docs/snapshotkit-source-review.md)
- [Screenshot 源码报告](./docs/screenshot-source-review.md)
