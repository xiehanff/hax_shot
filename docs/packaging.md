# Linux 打包与分发

Hax Shot 当前提供 **Fedora x86_64 RPM** 和 **Debian/Ubuntu amd64 DEB**。这是因为应用目标是 GNOME + Wayland，且截图链路依赖运行中的 Mutter ScreenCast、PipeWire、GStreamer 插件和 `wl-copy`；这些组件不适合被塞进一个“完全自包含”的 AppImage。

## 本地构建安装包

准备：

- FVM，并已执行 `fvm install`；
- Rust/Cargo；
- RPM：`rpmbuild`；DEB：`dpkg-deb`；
- `patchelf`；
- Flutter Linux 构建依赖。

执行：

```bash
fvm flutter build linux --release
./scripts/build_linux_rpm.sh --skip-build
./scripts/build_linux_deb.sh --skip-build
```

或者由脚本完成 Flutter Release 构建：

```bash
./scripts/build_linux_rpm.sh
./scripts/build_linux_deb.sh
```

产物位于：

```text
build/linux/x64/release/hax-shot-<version>-<release>.<arch>.rpm
build/linux/x64/release/hax-shot_<version>_amd64.deb
```

两个脚本的安装布局一致（都来自 `packaging/hax_shot.spec` 的约定）：bundle 整体放
`/opt/hax-shot`，`/usr/bin/hax_shot` 只是转发包装，桌面入口、图标和
`install-gnome-shortcut.sh` 装到系统标准位置。

## GitHub Actions 发布安装包

`.github/workflows/release.yml` 只监听版本 tag 的 push：

```yaml
on:
  push:
    tags: ['v*']
```

普通 `main` push、Pull Request 和手动运行都不会触发打包。tag 去掉 `v` 后必须等于 `pubspec.yaml` 中 `+` 之前的版本号。例如：

```text
pubspec.yaml: version: 1.3.0+1
Git tag:        v1.3.0
DEB:            hax-shot_1.3.0+1_amd64.deb
RPM:            hax-shot-1.3.0-1.x86_64.rpm（Fedora 本机构建会带 .fc44）
DMG:            HaxShot-1.3.0-arm64.dmg
```

本地检查通过后，创建并推送 tag：

```bash
fvm flutter analyze
fvm flutter test
cargo fmt --manifest-path rust/Cargo.toml --check
cargo check --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml

git tag -a v1.3.0 -m "Release v1.3.0"
git push origin v1.3.0
```

工作流会用同样的脚本构建 DEB 和 RPM（Linux 侧）以及 DMG（macOS 侧），并把产物同时保存为
Actions artifact、上传到对应 GitHub Release 的 Assets。Dart/Rust 检查由 `main` push 上的
`verify.yml` 负责，不在发布流程里重复。完整发布约定见
[CI 与 GitHub Release](./ci-release.md)。

脚本会把以下内容一起放进 `/opt/hax-shot`：

- Flutter runner 和 `libapp.so`；
- Flutter/plugin 动态库；
- Rust 原生库 `libhax_shot_native.so`；
- Flutter assets 和图标数据。

RPM 和 DEB 都安装：

```text
/usr/bin/hax_shot
/usr/share/applications/com.github.xiehanff.hax_shot.desktop
/usr/share/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
/usr/share/hax-shot/install-gnome-shortcut.sh
```

## 安装和卸载

```bash
sudo dnf install ./build/linux/x64/release/hax-shot-*.rpm
# 或者
sudo apt install ./build/linux/x64/release/hax-shot_*_amd64.deb
```

两个包都不会擅自修改当前用户的 GNOME 快捷键。安装后由用户执行：

```bash
/usr/share/hax-shot/install-gnome-shortcut.sh
```

这会把 `Alt+Z` 写入当前用户的 GNOME GSettings，并指向 `/usr/bin/hax_shot --capture`。

卸载：

```bash
sudo dnf remove hax-shot
# 或者
sudo apt remove hax-shot
```

卸载后如需删除用户自己的快捷键配置，可再次检查 GNOME 自定义快捷键列表；系统包不会替用户清理个人 GSettings。

## 运行时依赖

两个包都不捆绑 GNOME/Mutter、GTK、PipeWire、GStreamer 和 Wayland 工具，而是在包元数据里
声明运行依赖。其中的 `keybinder3` / `libkeybinder-3.0-0` 是 `hotkey_manager_linux` 链接的
全局快捷键库，Linux 构建也需要对应的开发包（`keybinder3-devel` / `libkeybinder-3.0-dev`）。
Fedora 侧（RPM）：

```text
gtk3
glib2
libstdc++
keybinder3
gstreamer1
gstreamer1-plugins-base
gstreamer1-plugins-good
pipewire
pipewire-gstreamer
wl-clipboard
libayatana-appindicator-gtk3
```

Debian/Ubuntu 侧（DEB，`build_linux_deb.sh` 的 `Depends`）：

```text
libgtk-3-0 (或 Ubuntu 24.04 的 libgtk-3-0t64)
libglib2.0-0 (或 libglib2.0-0t64)
libstdc++6
libkeybinder-3.0-0
libgstreamer1.0-0
gstreamer1.0-plugins-base
gstreamer1.0-plugins-good
libpipewire-0.3-0
wl-clipboard
libayatana-appindicator3-1
```

GNOME AppIndicator 扩展在 RPM 里作为推荐依赖提供。目标机器还必须运行 GNOME Wayland 会话，并提供 Mutter ScreenCast D-Bus 服务和 PipeWire 用户服务。

特别注意：安装成功不代表所有桌面环境都支持 Hax Shot。KDE、X11、wlroots、多显示器和没有 AppIndicator 的 GNOME 环境不在当前保证范围内。DEB 目前只在 Ubuntu 24.04（GNOME Wayland）验证过构建，未在 Debian 上实测安装。

## Rust 动态库为什么可以直接随包

Rust 不是运行时再安装的依赖。Flutter Release 构建期间，`linux/CMakeLists.txt` 会执行：

```text
cargo build --manifest-path rust/Cargo.toml --release
→ build/linux/x64/release/bundle/lib/libhax_shot_native.so
```

两个包都把整个 Flutter bundle 搬到 `/opt/hax-shot`，并通过相对 RPATH 保持：

```text
/opt/hax-shot/hax_shot                 → $ORIGIN/lib
/opt/hax-shot/lib/*.so                  → $ORIGIN
```

因此 Dart FFI 可以在安装后继续加载：

```text
/opt/hax-shot/lib/libhax_shot_native.so
```

包本身不需要携带 Rust 源码或 Cargo registry。

## 发布前检查

在 Fedora/Ubuntu GNOME Wayland 机器上安装 RPM（或 DEB）后，至少验证：

```bash
rpm -q hax-shot            # 或 dpkg -l hax-shot
ldd /opt/hax-shot/hax_shot
ldd /opt/hax-shot/lib/libhax_shot_native.so
gst-inspect-1.0 pipewiresrc
gst-inspect-1.0 pngenc
command -v wl-copy
/usr/share/hax-shot/install-gnome-shortcut.sh
```

然后重新登录或等待 GNOME Shell 刷新托盘，测试：

1. 托盘图标和菜单；
2. `Alt+Z`；
3. 选区保存；
4. PNG 图片剪贴板；
5. 设置页统一配置快捷键和登录自启动。

## 当前不发布 AppImage

AppImage 可以携带 Flutter bundle 和 Rust `.so`，但不能可靠携带并隔离 GNOME/Mutter ScreenCast、PipeWire 会话、GStreamer 插件和 Wayland 剪贴板协议。因此当前只发布 RPM 和 DEB；如果未来增加 AppImage，它只能作为依赖宿主 GNOME 服务的便携包，不能承诺完全自包含。
