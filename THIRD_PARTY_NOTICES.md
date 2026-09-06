# 第三方声明

## Hax Shot 自有内容

除本文件另有说明外，Hax Shot 的源代码和 `assets/icons/hax_shot.svg` 原创图标采用根目录的 [MIT License](./LICENSE)。由该 SVG 生成的 Hax Shot PNG 图标也属于本项目原创内容。

## 运行时和开发依赖

以下组件不是本项目源码的一部分，使用时仍受各自许可证约束：

- Flutter、Dart SDK 及 Flutter 官方组件；
- Dart 包：`ffi`、`window_manager`、`file_selector`、`tray_manager`、`hugeicons` 及其传递依赖；
- Rust crates：`gstreamer`、`futures-util`、`tokio`、`zbus` 及其传递依赖；
- GNOME、GTK、Mutter、PipeWire、GStreamer、libayatana-appindicator 和 `wl-clipboard`。

依赖源码没有复制进本仓库。具体许可证和版权信息以依赖包自身的 LICENSE/NOTICE 文件及发行版包信息为准。

## 参考项目

`references/` 下的仓库只用于本地源码阅读，不属于 Hax Shot 的运行时代码，也不会随 GitHub 源码提交：

- Reticle：Apache-2.0 + Commons Clause；
- SnapShotKit：MIT；
- Screenshot：本地副本未发现 LICENSE 正文，未复制其代码；
- snapclip：仅参考 GNOME Wayland ScreenCast/PipeWire 架构，未复制其实现代码。

