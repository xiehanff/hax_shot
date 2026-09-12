# Hax Shot 图标、Dock 和托盘

## 图标来源

三平台图标都从仓库里的单一源图生成：

```text
assets/icons/hax_shot_source.png   正方形（当前 1254×1254）、带透明背景
```

当前图标是灰蓝配色（主色 `#7387A6`），和 app 内主题色一致；整块图形自己带了
~7% 透明留白（圆角方形），所以生成时直接缩放，不再另外加内边距。

换了图标替换它，然后跑 `scripts/generate_icons.sh`（细节见
[`assets/generated_icons/README.md`](../assets/generated_icons/README.md)）。脚本会一次
生成 Linux 图标组、托盘 PNG/ICO、macOS AppIcon 和 Windows ico，不用手改尺寸表。其中
Windows 相关的 ICO 与资源只是**为将来保留**——Windows 平台本身未实现（见
[开发指南 §14](./development-guide.md#14-已知限制和未完成项)），脚本仍会照常生成它们。

- Flutter 托盘资源：`assets/icons/hax_shot.png`（Windows 用 `assets/icons/hax_shot.ico`，
  见 `lib/app.dart` 的 `trayIconAsset`）
- Linux 图标组：`linux/icons/hicolor/`（CMake 安装到 `share/icons/hicolor`，GNOME Dock
  和应用列表都用它）
- macOS：`macos/Runner/Assets.xcassets/AppIcon.appiconset/`
- Windows：`windows/runner/resources/app_icon.ico`（Windows 平台未实现，仅为将来保留）
- 生成尺寸：16、24、32、48、64、128、256、512px（macOS 另有 1024）

生成后的 Linux 图标已复制到：

```text
linux/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
```

另外还手工保留了 `linux/icons/hax_shot.png` 和 `linux/icons/com.github.xiehanff.hax_shot.png`
两份 256px 兼容副本：`scripts/generate_icons.sh` 不生成它们，也没有任何构建引用，属于
历史遗留的副本。外部图标资源的版权和许可应以原始资源为准。

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

Flutter 使用 `tray_manager`（`lib/app.dart` 的 `trayIconAsset`）：

| 平台 | 资源 | 说明 |
|---|---|---|
| macOS 菜单栏 | `assets/icons/hax_shot.png` | 彩色应用图标，和 Dock 图标同一张；**不要传 `isTemplate: true`**，那会把它渲染成纯色剪影 |
| Linux（AppIndicator） | `assets/icons/hax_shot.png` | 彩色，和 Dock 图标同一张 |
| Windows | `assets/icons/hax_shot.ico` | 必须是 `.ico` |

**为什么 macOS 用彩色应用图标而不是单色 template**：菜单栏图标是有意保持和应用图标一致的（产品要求）。
试过单色 template 方案（黑色 + 透明遮罩 + `isTemplate: true`），系统会按菜单栏外观反色，
但看起来就是另一个图标，不符合预期，已回退。代价是深色菜单栏上对比度偏低（图标自带深色底），
如果以后要改，先确认是不是真的接受“菜单栏图标和应用图标长得不一样”。托盘宿主还要等 Flutter 首帧后再创建
status item；窗口在 `runApp` 前隐藏时，太早创建会拿到临时菜单栏 frame，图标可能要等下一次
窗口活动（例如快捷键截图）才出现。

- 图标：`assets/icons/hax_shot.png`；
- 菜单：立即截屏、设置、退出；
- debug 构建额外多出一组“调试：…”入口（欢迎页 / 快捷键设置 / 权限引导 / 截图浮层 /
  AI 对话窗口），用来直接打开各个界面调 UI，见
  [`development-guide.md`](./development-guide.md#调试-ui-入口)；
- “设置”显示临时设置页，统一管理快捷键和登录自启动；
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

用户级安装会覆盖同名 desktop 条目，并刷新图标缓存；Wayland 下 GNOME Dock
可能继续使用旧缓存，注销并重新登录后生效。

并注册：

```text
Alt+Z → hax_shot --capture
```
