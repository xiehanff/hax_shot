#!/bin/bash
# 构建 macOS app，安装到 /Applications，并打一个 zip 方便分发/备份。
#
# 为什么必须装到 /Applications 而不是每次从 build/ 里跑：
#   macOS 的“屏幕录制”授权（TCC）是按 app 的路径 + 代码签名记的。从 build/ 目录
#   直接跑，权限会落到启动它的终端进程上；装到 /Applications 后双击启动，弹窗
#   上显示的才是 “Hax Shot”，授权也记在它自己身上。
#
# 用法：
#   scripts/install_macos_app.sh                # 构建 + 安装到 /Applications
#   scripts/install_macos_app.sh --dir ~/Apps   # 装到别的目录
set -euo pipefail

app_name="hax_shot"
bundle="hax_shot.app"
install_dir="/Applications"
zip_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      install_dir="${2:?--dir 需要参数}"
      shift 2
      ;;
    --zip)
      zip_path="${2:?--zip 需要参数}"
      shift 2
      ;;
    *)
      echo "error: 未知参数 $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
  echo "note: 使用 fvm flutter（项目固定 3.44.8）"
else
  flutter_cmd=(flutter)
fi

echo "note: 构建 release"
"${flutter_cmd[@]}" build macos --release

built="$repo_root/build/macos/Build/Products/Release/$bundle"
if [[ ! -d "$built" ]]; then
  echo "error: 没有找到构建产物 $built" >&2
  exit 1
fi

# 正在运行的实例会占住 bundle，替换前先退出（托盘宿主是常驻进程）。
if pgrep -x "$app_name" >/dev/null 2>&1; then
  echo "note: 退出正在运行的 $app_name"
  pkill -x "$app_name" || true
  sleep 1
fi

mkdir -p "$install_dir"
rm -rf "${install_dir:?}/$bundle"
cp -R "$built" "$install_dir/$bundle"
# 让 LaunchServices / Finder 立刻看到新的 bundle。
touch "$install_dir/$bundle"

if [[ -n "$zip_path" ]]; then
  mkdir -p "$(dirname "$zip_path")"
  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$install_dir/$bundle" "$zip_path"
  echo "note: 已打包 $zip_path"
fi

echo
echo "已安装: $install_dir/$bundle"
echo "签名  : $(codesign -dv "$install_dir/$bundle" 2>&1 | grep -m1 'Signature=' || true)"
echo
cat <<'TIP'
测试步骤：
  1. 打开 /Applications/hax_shot.app（Finder 双击，或 open -a hax_shot）
     —— 它是菜单栏应用：没有 Dock 图标，只在菜单栏右侧出现一个小图标
  2. 点菜单栏图标 → “立即截屏”
  3. 第一次系统会弹“hax_shot 想要录制此电脑的屏幕” → 打开系统设置并勾选 Hax Shot，
     然后回到菜单栏再点一次“立即截屏”
  4. 光标在哪块屏，冻结画面和框选浮层就出现在哪块屏；框选后可以：
     复制 / 保存 / 让 AI 翻译、解释、深入理解
  5. 想用快捷键：菜单栏图标 → “设置” → 录制一个组合键（例如 ⌘⇧Z）

注意：本机没有可用的代码签名证书（Apple Development 证书已被吊销），当前是
ad-hoc 签名。ad-hoc 签名每次重新构建都会换一个签名指纹，macOS 会认为这是“新的
app”，屏幕录制授权会失效、而且不一定再弹窗。遇到“截图失败：未授予屏幕录制权限”
时，去“系统设置 → 隐私与安全性 → 屏幕录制”把 Hax Shot 删掉再重新加一次即可。
想要以后重构建不用重新授权，可以做一个自签名证书（可以在 Keychain 里建，也可以
让我加一个 --dev-cert 到脚本里）。
TIP
