#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$PROJECT_DIR/build/linux/x64/release/bundle/easy_shot"
KEY_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/easy-shot/"
SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEY_PATH"
MEDIA_KEYS="org.gnome.settings-daemon.plugins.media-keys"

if [[ ! -x "$BINARY" ]]; then
  echo "找不到 release 可执行文件：$BINARY" >&2
  echo "请先运行：flutter build linux --release" >&2
  exit 1
fi

current="$(gsettings get "$MEDIA_KEYS" custom-keybindings)"
keybindings="$(python3 - "$current" "$KEY_PATH" <<'PY'
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
if path not in values:
    values.append(path)
print('[' + ', '.join(repr(value) for value in values) + ']')
PY
)"

gsettings set "$MEDIA_KEYS" custom-keybindings "$keybindings"
gsettings set "$SCHEMA" name 'Easy Shot Capture'
gsettings set "$SCHEMA" command "$BINARY --capture"
gsettings set "$SCHEMA" binding '<Alt>z'

applications_dir="$HOME/.local/share/applications"
icons_root="$HOME/.local/share/icons/hicolor"
icons_dir="$icons_root/256x256/apps"
mkdir -p "$applications_dir" "$icons_dir"
cp "$PROJECT_DIR/linux/icons/hicolor/index.theme" "$icons_root/index.theme"
cp -R "$PROJECT_DIR/linux/icons/hicolor/16x16" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/24x24" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/32x32" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/48x48" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/64x64" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/128x128" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/256x256" "$icons_root/"
cp -R "$PROJECT_DIR/linux/icons/hicolor/512x512" "$icons_root/"
desktop_file="$applications_dir/com.example.easy_shot.desktop"
cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=Easy Shot
Comment=Minimal Linux screenshot tool
Exec=$BINARY
Icon=com.example.easy_shot
Terminal=false
Type=Application
NoDisplay=true
Categories=Graphics;Utility;
StartupNotify=true
StartupWMClass=com.example.easy_shot
X-GNOME-WMClass=com.example.easy_shot
EOF

# Remove the old non-matching desktop ID so GNOME does not keep selecting
# the generic Flutter icon for this application.
rm -f "$applications_dir/easy-shot.desktop"
rm -f "$icons_root"/*/apps/easy_shot.png

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$icons_root" >/dev/null 2>&1 || true
fi

echo 'Easy Shot GNOME 快捷键已安装：Alt+Z'
echo "命令：$BINARY --capture"
