# 源码参考

这些仓库只作为本项目的交互和架构参考，当前使用浅克隆保存在本地：

| 目录 | 仓库 | 用途 | 许可证备注 |
|---|---|---|---|
| `reticle` | https://github.com/croc100/Reticle | 冻结画面、框选、标注、贴图、后处理流程 | Apache-2.0 + Commons Clause；先参考，不直接复制代码 |
| `snapshotkit` | https://github.com/bheemrc/SnapShotKit | 原生截图、编辑器和服务拆分 | MIT |
| `screenshot` | https://github.com/tyypgzl/screenshot | 轻量菜单栏截图、快捷键和 AppKit 组织方式 | 当前仓库未发现 LICENSE，先不复制代码 |
| `snapclip` | https://github.com/gitoffmylibrary/snapclip | GNOME Wayland 的 Mutter ScreenCast + PipeWire 无快门声单帧捕获 | 仅参考架构，不复制 Python/GTK 代码 |

当前 MVP 的主参考是 `reticle` 和 `snapclip`：前者提供冻结画面/框选流程，后者解决 GNOME Wayland 截图快门声问题。本项目使用 Flutter + Rust 重写，不移植 Swift/AppKit/Python/GTK 实现。
