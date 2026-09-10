#!/bin/bash
# 以「正确的身份」启动 macOS debug 构建，用于调试需要权限的功能。
#
# 为什么不直接 flutter run：
#   macOS 的屏幕录制授权记在**责任进程**上。`flutter run` 启动的 app 是终端的子
#   进程，责任进程是终端 —— 系统弹窗会写“终端想要录制屏幕”，授权也记在终端名下，
#   Hax Shot 自己不会出现在“系统设置 → 隐私与安全性 → 屏幕录制”列表里（macOS 15
#   的该面板也没有“+”可以手动添加），于是怎么都授权不了。
#   用 Finder / `open` 启动时，责任进程才是 Hax Shot 自己，弹窗和列表里都是它。
#
# 用法：
#   scripts/run_macos_debug.sh            # 构建 debug 并用 open 启动
#   scripts/run_macos_debug.sh --release  # 用 release 构建
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

mode="debug"
if [[ "${1:-}" == "--release" ]]; then
  mode="release"
fi

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
else
  flutter_cmd=(flutter)
fi

echo "note: 构建 ${mode}"
"${flutter_cmd[@]}" build macos "--${mode}"

case "$mode" in
  debug) app_path="$repo_root/build/macos/Build/Products/Debug/hax_shot.app" ;;
  *) app_path="$repo_root/build/macos/Build/Products/Release/hax_shot.app" ;;
esac

if [[ ! -d "$app_path" ]]; then
  echo "error: 找不到 ${app_path}" >&2
  exit 1
fi

echo "note: 用 open 启动（让 Hax Shot 成为责任进程，权限才记在它身上）"
open "$app_path"

cat <<'TIP'

它是菜单栏应用：没有 Dock 图标，只在菜单栏右侧出现一个小图标。
按 ⌥Z（或菜单栏图标 → 立即截屏）→ 首次会弹授权引导 →「打开系统设置」
→ 在“屏幕录制”里勾选 hax_shot → 回来点「我已授权，重新检查」（会自动重启抓屏进程）。

顺手的命令：
  查看权限状态（无需弹窗）：  /tmp/preflight   # 若不存在：见 docs/development-guide.md
  清掉错位的授权记录：        tccutil reset ScreenCapture com.github.xiehanff.haxShot
TIP
