#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_BINARY="$PROJECT_DIR/build/linux/x64/release/bundle/hax_shot"
BINARY="${HAX_SHOT_BINARY:-}"
if [[ -z "$BINARY" ]]; then
  if [[ -x "$SOURCE_BINARY" ]]; then
    BINARY="$SOURCE_BINARY"
  elif command -v hax_shot >/dev/null 2>&1; then
    BINARY="$(command -v hax_shot)"
  fi
fi

KEY_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hax-shot/"
LEGACY_KEY_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/easy-shot/"
SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEY_PATH"
LEGACY_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$LEGACY_KEY_PATH"
MEDIA_KEYS="org.gnome.settings-daemon.plugins.media-keys"

if [[ -z "$BINARY" || ! -x "$BINARY" ]]; then
  echo "找不到 Hax Shot 可执行文件。" >&2
  echo "源码项目请先运行：fvm flutter build linux --release" >&2
  echo "RPM 安装后请确认 /usr/bin/hax_shot 已存在。" >&2
  exit 1
fi

current="$(gsettings get "$MEDIA_KEYS" custom-keybindings)"
keybindings="$(python3 - "$current" "$KEY_PATH" "$LEGACY_KEY_PATH" <<'PY'
import ast
import sys

raw = sys.argv[1].strip()
if raw.startswith('@as '):
    raw = raw[4:]
try:
    values = list(ast.literal_eval(raw))
except (SyntaxError, ValueError):
    values = []
path = sys.argv[2]
legacy_path = sys.argv[3]
values = [value for value in values if value != legacy_path]
if path not in values:
    values.append(path)
print('[' + ', '.join(repr(value) for value in values) + ']')
PY
)"

gsettings set "$MEDIA_KEYS" custom-keybindings "$keybindings"
gsettings reset-recursively "$LEGACY_SCHEMA" >/dev/null 2>&1 || true
gsettings set "$SCHEMA" name 'Hax Shot Capture'
gsettings set "$SCHEMA" command "$BINARY --capture"
gsettings set "$SCHEMA" binding '<Alt>z'

applications_dir="$HOME/.local/share/applications"
icons_root="$HOME/.local/share/icons/hicolor"
icons_dir="$icons_root/256x256/apps"
mkdir -p "$applications_dir" "$icons_dir"
icon_source_dir="$PROJECT_DIR/linux/icons/hicolor"
if [[ -d "$icon_source_dir" ]]; then
  cp "$icon_source_dir/index.theme" "$icons_root/index.theme"
  cp -R "$icon_source_dir/16x16" "$icons_root/"
  cp -R "$icon_source_dir/24x24" "$icons_root/"
  cp -R "$icon_source_dir/32x32" "$icons_root/"
  cp -R "$icon_source_dir/48x48" "$icons_root/"
  cp -R "$icon_source_dir/64x64" "$icons_root/"
  cp -R "$icon_source_dir/128x128" "$icons_root/"
  cp -R "$icon_source_dir/256x256" "$icons_root/"
  cp -R "$icon_source_dir/512x512" "$icons_root/"
fi
desktop_file="$applications_dir/com.github.xiehanff.hax_shot.desktop"
cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=Hax Shot
Comment=Minimal Linux screenshot tool
Exec=$BINARY
Icon=com.github.xiehanff.hax_shot
Terminal=false
Type=Application
NoDisplay=false
Categories=Graphics;Utility;
StartupNotify=true
StartupWMClass=com.github.xiehanff.hax_shot
X-GNOME-WMClass=com.github.xiehanff.hax_shot
EOF

# Remove the old non-matching desktop ID so GNOME does not keep selecting
# the generic Flutter icon for this application.
rm -f "$applications_dir/hax-shot.desktop"
rm -f "$icons_root"/*/apps/easy_shot.png
rm -f "$icons_root"/*/apps/hax_shot.png

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$icons_root" >/dev/null 2>&1 || true
fi

echo 'Hax Shot GNOME 快捷键已安装：Alt+Z'
echo "命令：$BINARY --capture"
