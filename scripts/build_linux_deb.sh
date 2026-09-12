#!/usr/bin/env bash
# 把 Flutter release bundle 打成 Debian/Ubuntu 的 .deb。布局与 Fedora 的 RPM 保持一致
# （见 packaging/hax_shot.spec）：bundle 整体放 /opt/hax-shot，桌面入口和图标装到系统
# 标准位置，/usr/bin/hax_shot 只是一个转发包装。
#
# 用法：
#   ./scripts/build_linux_deb.sh               # 先构建再打包
#   ./scripts/build_linux_deb.sh --skip-build  # 复用已构建的 bundle（CI 用这个）
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
skip_build=false

if [[ "${1:-}" == "--skip-build" ]]; then
  skip_build=true
fi

full_version="$(sed -n 's/^version:[[:space:]]*//p' "$repo_root/pubspec.yaml" | head -n 1)"
if [[ -z "$full_version" ]]; then
  printf 'Missing version in pubspec.yaml\n' >&2
  exit 1
fi

bundle_dir="$repo_root/build/linux/x64/release/bundle"
deb_output_dir="$repo_root/build/linux/x64/release"
deb_artifact="$deb_output_dir/hax-shot_${full_version}_amd64.deb"

if [[ "$skip_build" == false ]]; then
  if ! command -v fvm >/dev/null 2>&1; then
    printf 'fvm is required; run: fvm install\n' >&2
    exit 1
  fi
  fvm flutter build linux --release
fi

if [[ ! -x "$bundle_dir/hax_shot" ]]; then
  printf 'Linux release bundle not found: %s\n' "$bundle_dir" >&2
  printf 'Run fvm flutter build linux --release first.\n' >&2
  exit 1
fi

if [[ ! -f "$bundle_dir/lib/libhax_shot_native.so" ]]; then
  printf 'Rust native library not found in bundle: %s\n' \
    "$bundle_dir/lib/libhax_shot_native.so" >&2
  exit 1
fi

for command_name in dpkg-deb patchelf; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '%s is required to build the DEB package\n' "$command_name" >&2
    exit 1
  fi
done

pkg_root="$(mktemp -d)"
trap 'rm -rf "$pkg_root"' EXIT
mkdir -p \
  "$pkg_root/DEBIAN" \
  "$pkg_root/opt" \
  "$pkg_root/usr/bin" \
  "$pkg_root/usr/share/applications" \
  "$pkg_root/usr/share/hax-shot"

# 整个 Flutter bundle 必须连在一起：Dart FFI 靠 <executable-dir>/lib/
# libhax_shot_native.so 找 Rust cdylib。
cp -a "$bundle_dir" "$pkg_root/opt/hax-shot"
# 桌面集成装到系统标准位置，去掉 Flutter 放在 bundle 里的那份拷贝。
rm -rf "$pkg_root/opt/hax-shot/share"

cp -a "$repo_root/linux/icons/hicolor" "$pkg_root/usr/share/icons/"
# index.theme 属于 hicolor-icon-theme 包，不要重复声明所有权。
rm -f "$pkg_root/usr/share/icons/hicolor/index.theme"

sed 's|^Exec=hax_shot$|Exec=/usr/bin/hax_shot|' \
  "$repo_root/packaging/hax_shot.desktop" > \
  "$pkg_root/usr/share/applications/com.github.xiehanff.hax_shot.desktop"

install -m 0755 "$repo_root/scripts/install-gnome-shortcut.sh" \
  "$pkg_root/usr/share/hax-shot/install-gnome-shortcut.sh"
install -m 0644 "$repo_root/LICENSE" \
  "$pkg_root/usr/share/hax-shot/LICENSE"
install -m 0644 "$repo_root/README.md" \
  "$pkg_root/usr/share/hax-shot/README.md"
install -m 0644 "$repo_root/THIRD_PARTY_NOTICES.md" \
  "$pkg_root/usr/share/hax-shot/THIRD_PARTY_NOTICES.md"

# 和 RPM 一样给一个稳定命令：桌面入口和 GNOME 快捷键都指向它，真正的可执行文件
# 仍然通过 /proc/self/exe 解析自己的 bundle 目录。
cat > "$pkg_root/usr/bin/hax_shot" <<'EOF'
#!/bin/sh
exec /opt/hax-shot/hax_shot "$@"
EOF
chmod 0755 "$pkg_root/usr/bin/hax_shot"

# Flutter bundle 可能残留构建机的 RUNPATH，安装前全部改成相对路径。
patchelf --set-rpath '$ORIGIN/lib' "$pkg_root/opt/hax-shot/hax_shot"
find "$pkg_root/opt/hax-shot/lib" -type f -name '*.so*' \
  -exec patchelf --set-rpath '$ORIGIN' {} +

# 与 RPM spec 的 Requires 对齐：GNOME/Mutter、GStreamer 和 PipeWire 都不随包捆绑；
# keybinder 是 hotkey_manager_linux 链接的全局快捷键库。t64 后缀是 Ubuntu 24.04 的
# 时间戳 ABI 重命名，别名写在前面让两边都能装上。
# note: control 文件不能带注释行，说明只能写在这里。
cat > "$pkg_root/DEBIAN/control" <<EOF
Package: hax-shot
Version: $full_version
Section: graphics
Priority: optional
Architecture: amd64
Maintainer: xiehan <chinkout@163.com>
Depends: libc6, libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6,
 libkeybinder-3.0-0,
 libgstreamer1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good,
 libpipewire-0.3-0, wl-clipboard, libayatana-appindicator3-1
Recommends: gnome-shell-extension-appindicator
Description: Tray-only screenshot tool for GNOME Wayland
 Hax Shot captures a silent frozen frame through Mutter ScreenCast and PipeWire,
 then provides rectangle selection, PNG saving, and image clipboard support.
EOF

cat > "$pkg_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
chmod +x /opt/hax-shot/hax_shot
exit 0
EOF
chmod 0755 "$pkg_root/DEBIAN/postinst"

cat > "$pkg_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  fi
fi
exit 0
EOF
chmod 0755 "$pkg_root/DEBIAN/postrm"

mkdir -p "$deb_output_dir"
rm -f "$deb_artifact"
dpkg-deb --build --root-owner-group "$pkg_root" "$deb_artifact"
printf 'DEB release package: %s\n' "$deb_artifact"
