#!/bin/bash
# 从一个源图生成三平台需要的所有图标。
#
# 源：assets/icons/hax_shot_source.png（正方形、带透明背景）。换了图标只要替换这个
# 文件，然后跑一次本脚本即可。（assets/icons/hax_shot.svg 是上一版设计，保留作参考，
# 不再作为生成源。）
#
# 产出：
#   assets/icons/hax_shot.png                 托盘图标（Linux AppIndicator / macOS 菜单栏）
#   assets/icons/hax_shot.ico                 Windows 托盘图标（tray_manager 用 LoadImage
#                                             读 IMAGE_ICON，必须是 .ico，PNG 不行）
#   linux/icons/hicolor/<size>/apps/com.github.xiehanff.hax_shot.png
#                                             Linux 应用图标 = GNOME Dock / 应用列表图标
#                                             （CMake 安装它，RPM 也打它）
#   assets/generated_icons/linux/...          同一套图的副本，myblog 的项目卡片引用这个路径
#   macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_<size>.png
#   windows/runner/resources/app_icon.ico     Windows 可执行文件/窗口图标
#
# 注意：Windows 平台本身未实现（Rust 后端、Windows 构建规则、原生边界都缺，
# flutter build windows 不可用，见 docs/development-guide.md §14）。ICO 与 windows/
# 下的资源仍照常生成，只是为将来保留。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

source_png="assets/icons/hax_shot_source.png"
if [[ ! -f "$source_png" ]]; then
  echo "error: 找不到源图 ${source_png}" >&2
  exit 1
fi

width="$(sips -g pixelWidth "$source_png" | tail -1 | awk '{print $2}')"
height="$(sips -g pixelHeight "$source_png" | tail -1 | awk '{print $2}')"
if [[ "$width" != "$height" ]]; then
  echo "error: 源图必须是正方形，当前 ${width}x${height}" >&2
  exit 1
fi
echo "源图：${source_png} (${width}x${height})"

resize() {
  local size="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  sips -s format png -z "$size" "$size" "$source_png" --out "$out" >/dev/null
}

# ---------------------------------------------------------------- Linux / 托盘 PNG
linux_sizes=(16 24 32 48 64 128 256 512)
for size in "${linux_sizes[@]}"; do
  resize "$size" "linux/icons/hicolor/${size}x${size}/apps/com.github.xiehanff.hax_shot.png"
  resize "$size" "assets/generated_icons/linux/icons/hicolor/${size}x${size}/apps/hax_shot.png"
done
# 托盘用 256：Linux 的 AppIndicator 和 macOS 菜单栏都会自己缩放。
resize 256 "assets/icons/hax_shot.png"

# ---------------------------------------------------------------- macOS AppIcon
for size in 16 32 64 128 256 512 1024; do
  resize "$size" "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
done

# ---------------------------------------------------------------- Windows .ico
# Windows 平台未实现（见 docs/development-guide.md §14），这段仍保留：ICO 只是给将来
# 的 Windows 支持预留。
# 直接内嵌 PNG（Windows Vista+ 支持 PNG 压缩的图标项），这样不必在这里手写
# BITMAPINFOHEADER + AND 掩码。
ico_tmp="$(mktemp -d)"
trap 'rm -rf "$ico_tmp"' EXIT
for size in 16 24 32 48 64 128 256; do
  resize "$size" "$ico_tmp/icon_${size}.png"
done
mkdir -p windows/runner/resources
python3 - "$ico_tmp" "assets/icons/hax_shot.ico" <<'PY'
import struct, sys, pathlib

tmp_dir = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
sizes = [16, 24, 32, 48, 64, 128, 256]

images = []
for size in sizes:
    data = (tmp_dir / f"icon_{size}.png").read_bytes()
    images.append((size, data))

# ICONDIR: reserved, type(1=icon), count
header = struct.pack("<HHH", 0, 1, len(images))
entries = b""
payload = b""
offset = len(header) + 16 * len(images)
for size, data in images:
    # 宽高 256 在 ICONDIR 里写 0
    dim = 0 if size >= 256 else size
    entries += struct.pack(
        "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset
    )
    payload += data
    offset += len(data)
out_path.write_bytes(header + entries + payload)
print(f"  {out_path} ({len(images)} 个尺寸：{', '.join(str(s) for s in sizes)})")
PY

# ---------------------------------------------------------------- 汇总
cp -f "assets/icons/hax_shot.ico" "windows/runner/resources/app_icon.ico"

echo "已生成："
echo "  Linux 应用/Dock 图标：linux/icons/hicolor/*/apps/（$(ls linux/icons/hicolor | wc -l | tr -d ' ') 个尺寸目录）"
echo "  托盘 PNG：assets/icons/hax_shot.png"
echo "  托盘 ICO：assets/icons/hax_shot.ico"
echo "  macOS AppIcon：macos/Runner/Assets.xcassets/AppIcon.appiconset/"
echo "  Windows 可执行文件图标：windows/runner/resources/app_icon.ico"
