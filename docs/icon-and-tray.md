# Hax Shot 图标、Dock 和托盘

## 图标来源

Hax Shot 使用项目原创的截图工具图标，不再依赖第三方产品图标：

- SVG 源文件：`assets/icons/hax_shot.svg`
- Flutter 托盘资源：`assets/icons/hax_shot.png`
- 生成目录：`assets/generated_icons/`

生成后的 Linux 图标已复制到：

```text
linux/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
```

同时保留 `linux/icons/hax_shot.png` 和 `linux/icons/com.github.xiehanff.hax_shot.png` 的
256px 兼容副本。图标源文件和生成文件均属于本项目 MIT 许可内容。

## Dock 图标

Hax Shot 普通进程是 tray-only，不显示主应用窗口，也不进入任务栏；下面的
desktop/icon 配置主要用于 GNOME 识别临时 `--capture` 窗口和安装入口。

Linux 原生窗口在 `linux/runner/my_application.cc` 中通过：

```text
gtk_window_set_icon_from_file()
```

加载 bundle 内的：

```text
data/hax_shot_icon.png
```

同时通过 `gtk_window_set_icon_name(APPLICATION_ID)` 使用 hicolor 图标组。
CMake 安装：

```text
share/applications/com.github.xiehanff.hax_shot.desktop
share/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
```

## 托盘图标

Flutter 使用 `tray_manager`：

- 图标：`assets/icons/hax_shot.png`；
- 菜单：立即截屏、修改快捷键、退出；
- “修改快捷键”显示临时设置页，展示当前快捷键、删除按钮和录制新快捷键入口；
- 普通进程不显示主窗口；
- 托盘菜单的“立即截屏”启动新的 `hax_shot --capture` 进程；
- 左键点击图标不打开主窗口，右键使用原生托盘菜单。

GNOME Linux 依赖 AppIndicator 扩展。Fedora 开发环境已安装：

```text
libayatana-appindicator-gtk3-devel
gnome-shell-extension-appindicator
```

`tray_manager` 的 Linux 实现不支持 `setToolTip` 和 `popUpContextMenu`，因此 Hax Shot 没有调用这两个未实现的方法；右键菜单由 AppIndicator 原生处理。

## 安装快捷键和用户图标

```bash
./scripts/install-gnome-shortcut.sh
```

脚本会安装并刷新图标缓存：

```text
~/.local/share/applications/com.github.xiehanff.hax_shot.desktop
~/.local/share/icons/hicolor/index.theme
~/.local/share/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
```

并注册：

```text
Alt+Z → hax_shot --capture
```
