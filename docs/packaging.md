# Linux 打包与分发

Hax Shot 当前优先提供 **Fedora x86_64 RPM**。这是因为应用目标是 Fedora GNOME + Wayland，且截图链路依赖运行中的 Mutter ScreenCast、PipeWire、GStreamer 插件和 `wl-copy`；这些组件不适合被塞进一个“完全自包含”的 AppImage。

## 本地构建 RPM

准备：

- FVM，并已执行 `fvm install`；
- Rust/Cargo；
- `rpmbuild`；
- `patchelf`；
- Flutter Linux 构建依赖。

执行：

```bash
fvm flutter build linux --release
./scripts/build_linux_rpm.sh --skip-build
```

或者由脚本完成 Flutter Release 构建：

```bash
./scripts/build_linux_rpm.sh
```

产物位于：

```text
build/linux/x64/release/hax-shot-<version>-<release>.<arch>.rpm
```

脚本会把以下内容一起放进 `/opt/hax-shot`：

- Flutter runner 和 `libapp.so`；
- Flutter/plugin 动态库；
- Rust 原生库 `libhax_shot_native.so`；
- Flutter assets 和图标数据。

RPM 同时安装：

```text
/usr/bin/hax_shot
/usr/share/applications/com.github.xiehanff.hax_shot.desktop
/usr/share/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png
/usr/share/hax-shot/install-gnome-shortcut.sh
```

## 安装和卸载

```bash
sudo dnf install ./build/linux/x64/release/hax-shot-*.rpm
```

RPM 安装不会擅自修改当前用户的 GNOME 快捷键。安装后由用户执行：

```bash
/usr/share/hax-shot/install-gnome-shortcut.sh
```

这会把 `Alt+Z` 写入当前用户的 GNOME GSettings，并指向 `/usr/bin/hax_shot --capture`。

卸载：

```bash
sudo dnf remove hax-shot
```

卸载后如需删除用户自己的快捷键配置，可再次检查 GNOME 自定义快捷键列表；系统包不会替用户清理个人 GSettings。

## 运行时依赖

RPM 不捆绑 GNOME/Mutter、GTK、PipeWire、GStreamer 和 Wayland 工具，而是声明 Fedora 运行依赖：

```text
gtk3
glib2
libstdc++
gstreamer1
gstreamer1-plugins-base
gstreamer1-plugins-good
pipewire
pipewire-gstreamer
wl-clipboard
libayatana-appindicator-gtk3
```

GNOME AppIndicator 扩展作为推荐依赖提供。目标机器还必须运行 GNOME Wayland 会话，并提供 Mutter ScreenCast D-Bus 服务和 PipeWire 用户服务。

特别注意：RPM 安装成功不代表所有桌面环境都支持 Hax Shot。KDE、X11、wlroots、多显示器和没有 AppIndicator 的 GNOME 环境不在当前保证范围内。

## Rust 动态库为什么可以直接随包

Rust 不是运行时再安装的依赖。Flutter Release 构建期间，`linux/CMakeLists.txt` 会执行：

```text
cargo build --manifest-path rust/Cargo.toml --release
→ build/linux/x64/release/bundle/lib/libhax_shot_native.so
```

RPM 将整个 Flutter bundle 搬到 `/opt/hax-shot`，并通过相对 RPATH 保持：

```text
/opt/hax-shot/hax_shot                 → $ORIGIN/lib
/opt/hax-shot/lib/*.so                  → $ORIGIN
```

因此 Dart FFI 可以在安装后继续加载：

```text
/opt/hax-shot/lib/libhax_shot_native.so
```

RPM 不需要携带 Rust 源码或 Cargo registry。

## 发布前检查

在 Fedora GNOME Wayland 机器上安装 RPM 后，至少验证：

```bash
rpm -q hax-shot
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
5. 设置页修改快捷键。

## 当前不发布 AppImage

AppImage 可以携带 Flutter bundle 和 Rust `.so`，但不能可靠携带并隔离 GNOME/Mutter ScreenCast、PipeWire 会话、GStreamer 插件和 Wayland 剪贴板协议。因此当前先发布 RPM；如果未来增加 AppImage，它只能作为依赖宿主 Fedora GNOME 服务的便携包，不能承诺完全自包含。
