# 第三方声明

## Hax Shot 自有内容

Hax Shot 源代码采用根目录的 [MIT License](./LICENSE)。当前应用图标由外部 `.icns` 资源生成，图标版权和许可应以原始资源为准，不作为本项目原创内容声明。

## 运行时和开发依赖

以下组件不是本项目源码的一部分，使用时仍受各自许可证约束：

- Flutter、Dart SDK 及 Flutter 官方组件；
- Dart 包：`ffi`、`window_manager`、`file_selector`、`tray_manager`、`hugeicons`、`get`、`http`、`shared_preferences`、`desktop_drop` 及其传递依赖；
- Rust crates：`gstreamer`、`futures-util`、`tokio`、`zbus` 及其传递依赖；
- GNOME、GTK、Mutter、PipeWire、GStreamer、libayatana-appindicator 和 `wl-clipboard`。

依赖源码没有复制进本仓库。具体许可证和版权信息以依赖包自身的 LICENSE/NOTICE 文件及发行版包信息为准。

## 随仓库分发的字体资源

`assets/fonts/GBaiMarkerPen.ttf`（10.3 MiB）**不是 Hax Shot 原创内容**，随仓库一起分发：

- 字体名：`851 GBai Marker` / `851 GBai 记号笔`（pubspec 里声明为 family `GBaiMarkerPen`，全文只用于 AI 面板顶部条的 `HaxShot` 字标）；
- 版本：`Version 0.04`；字体内嵌版权行：`copyright 8:51:22 pm, edited by lamda05`；
- 来源：从本机另一个项目 `cliper`（`assets/fonts/GBaiMarkerPen.ttf`）复制而来，该项目的 CHANGELOG 记作「集成 851 GBai 马克笔体（GBaiMarkerPen）作为标题品牌字体」，没有附带 LICENSE/NOTICE；
- 该字体文件内部 `name` 表没有 license 字段（ID 13/14 为空），因此本仓库**未能从字体文件或来源项目自动确认再分发许可**。

许可状态：字体版权由本项目作者持有，许可文本待补充（补齐前不要把该字体用于对外分发，或按项目作者的说明替换为可确认许可的替代字体）。

## 参考项目

`references/` 下的仓库只用于本地源码阅读，不属于 Hax Shot 的运行时代码，也不会随 GitHub 源码提交：

- Reticle：Apache-2.0 + Commons Clause；
- SnapShotKit：MIT；
- Screenshot：本地副本未发现 LICENSE 正文，未复制其代码；
- snapclip：仅参考 GNOME Wayland ScreenCast/PipeWire 架构，未复制其实现代码。

