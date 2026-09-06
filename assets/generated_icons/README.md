# 图标组: easy_shot

- 主图来源: Proton_Pass-4022f38d0f.icns 中最大表示 ic[ic10] 1024x1024
- 生成时间: 2026-09-06 11:41:16
- 写入前已有内容自动备份于同级 `*-backup-*` 目录

## 各平台用法

- **macOS**: 将 `macos/easy_shot.iconset` 打包结果 `easy_shot.icns` 放入 Xcode asset 或 .app 的 `Contents/Resources/`
- **iOS**: 将 `ios/AppIcon.appiconset/` 整个目录拖入 Xcode 的 `Assets.xcassets`
- **Android**: 将 `android/res/` 下各 `mipmap-*` 目录合并进项目 `app/src/main/res/` (AndroidManifest 已引用 `@mipmap/ic_launcher` 即可)
- **Windows**: 将 `windows/app_icon.ico` 用于打包配置 (Electron `build.win.icon`、Qt `.rc` 文件、MSIX 等)
- **Linux**: 将 `linux/icons/hicolor/` 下各尺寸 PNG 复制到 `~/.local/share/icons/hicolor/`(用户)或 `/usr/share/icons/hicolor/`(系统), 然后 `gtk-update-icon-cache`
