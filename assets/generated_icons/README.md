# Hax Shot 图标资源

三平台图标都从**一个源图**生成：

```text
assets/icons/hax_shot_source.png   正方形、带透明背景（当前 1254x1254）
```

换图标时替换这个文件，然后在仓库根目录跑一次：

```bash
scripts/generate_icons.sh
```

产出：

| 路径 | 用途 |
|---|---|
| `assets/icons/hax_shot.png` | 托盘图标（Linux AppIndicator / macOS 菜单栏），256px |
| `assets/icons/hax_shot.ico` | Windows 托盘图标（tray_manager 用 `LoadImage(IMAGE_ICON)`，必须是 `.ico`） |
| `linux/icons/hicolor/<size>/apps/com.github.xiehanff.hax_shot.png` | Linux 应用图标 = GNOME Dock / 应用列表（CMake 安装、RPM 打包都用它） |
| `assets/generated_icons/linux/...` | 同一套图的副本；myblog 的项目卡片引用这个路径，所以两份必须保持一致 |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_<size>.png` | macOS AppIcon（16–1024） |
| `windows/runner/resources/app_icon.ico` | Windows 可执行文件/窗口图标 |

说明：

- `.ico` 内嵌 PNG（Windows Vista+ 支持 PNG 压缩的图标项），所以脚本里不需要手写
  BITMAPINFOHEADER + AND 掩码；
- `assets/icons/hax_shot.svg` 是**上一版**设计，保留作参考，不再作为生成源（脚本只读
  `hax_shot_source.png`，避免误用旧图标）；
- macOS 图标里 1024 是从源图直接缩放的（源图 1254 足够清晰）。
