# Hax Shot 源码参考阅读索引

这些文档记录了对本地源码参考仓库的实际阅读结果。其他 Agent 开始实现前，应先阅读本页和对应的专题报告。

## 参考仓库

| 优先级 | 报告 | 本地路径 | 主要用途 |
|---|---|---|---|
| 1 | [Reticle 源码阅读](./reticle-source-review.md) | `references/reticle` | 截图工具完整产品流程、冻结覆盖层、贴图、输出流水线 |
| 2 | [SnapShotKit 源码阅读](./snapshotkit-source-review.md) | `references/snapshotkit` | 坐标规范、像素尺寸、统一 flatten、保存和剪贴板 |
| 3 | [Screenshot 源码阅读](./screenshot-source-review.md) | `references/screenshot` | 轻量截图主链路、单帧捕获、选区 overlay、复制和保存 |
| 4 | [snapclip 源码阅读](./snapclip-source-review.md) | `references/snapclip` | GNOME Wayland Mutter ScreenCast + PipeWire 无快门声单帧捕获 |
| — | [MVP 参考结论](./reference-decisions.md) | — | 将 macOS 设计转换为 Hax Shot 的 Flutter + Rust + Linux 方案 |
| — | [图标、Dock 和托盘](./icon-and-tray.md) | `assets/icons`、`linux/icons` | 原创图标和 Linux 桌面集成 |

| — | [当前实现与开发指南](./development-guide.md) | 当前代码入口、运行方式、坑点、验证和交接信息 |
| — | [MVP2 功能说明](./mvp2.md) | 自启动、矩形、箭头、文字标注和导出坐标 |
| — | [Linux 打包与分发](./packaging.md) | Fedora RPM、Rust 动态库、系统运行依赖和安装流程 |
| — | [CI 与 GitHub Release](./ci-release.md) | 版本 tag 触发 RPM 构建并上传 GitHub Release |

## 结论先看

Hax Shot MVP1 只实现基础截图链路；MVP2 在此基础上增加自启动、矩形、箭头和文字标注，详见 [MVP2 功能说明](./mvp2.md)。

```text
Alt+Z
  → Mutter ScreenCast 获取无快门声冻结图
  → Flutter 框选
  → 保存 PNG / 复制图片剪贴板
```

- Flutter：截图预览、框选、工具栏和状态提示。
- Rust：Mutter ScreenCast/PipeWire 单帧截图、PNG 管线、Wayland 图片剪贴板。
- GNOME Wayland 的组合快捷键：MVP 由系统自定义 `Alt+Z` 启动 `hax_shot --capture`，不在 Flutter 内部伪造全局热键。
- Reticle、SnapShotKit、Screenshot 的 Swift/AppKit 代码只作为行为和边界参考，不直接复制；snapclip 只参考 GNOME ScreenCast 管线。

## 许可证提醒

- Hax Shot 自有源代码和原创图标：MIT，见根目录 [`LICENSE`](../LICENSE)。
- Reticle：Apache-2.0 + Commons Clause，不能按普通 Apache-2.0 直接复用。
- SnapShotKit：MIT，可以在保留版权和许可证的前提下参考/复用。
- Screenshot：README 声称 MIT，但本地仓库没有 `LICENSE` 正文；在上游确认前不复制代码。
- 参考仓库只用于本地阅读，克隆目录已加入 Git 忽略，不随项目发布。
