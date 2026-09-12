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
#   scripts/install_macos_app.sh --dev-cert     # 顺手用本地自签名证书签名（见 6.2）
#   scripts/install_macos_app.sh --dir ~/Apps   # 装到别的目录
set -euo pipefail

app_name="hax_shot"
bundle="hax_shot.app"
install_dir="/Applications"
zip_path=""
dev_cert=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-cert)
      # 用本地自签名证书签名（scripts/macos_dev_cert.sh 创建）。理由见
      # docs/development-guide.md 6.2：ad-hoc 签名下屏幕录制授权绑 cdhash，
      # 每次构建都失效、而且会从“屏幕录制”列表里消失；固定证书后授权不再丢。
      dev_cert=true
      shift
      ;;
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

if [[ "$dev_cert" == true ]]; then
  identity="Hax Shot Dev"
  dev_keychain="$HOME/Library/Keychains/hax-shot-dev.keychain-db"
  if ! security find-identity -v -p codesigning "$dev_keychain" 2>/dev/null | grep -q "$identity"; then
    echo "error: 找不到可用的签名身份“${identity}”。先跑：" >&2
    echo "         scripts/macos_dev_cert.sh --trust" >&2
    exit 1
  fi
  echo "note: 用 ${identity} 重新签名（保留 entitlements，换成证书形式的 requirement）"
  # codesign 只在「keychain 搜索列表」里的 keychain 中找签名身份：证书放进独立
  # keychain 后必须把它加进搜索列表，否则即使 find-identity 能列出这个身份，
  # codesign --sign 也会报 "The specified item could not be found in the keychain"。
  if ! security list-keychains -d user | grep -qF "$dev_keychain"; then
    echo "note: 把 ${identity} 的 keychain 加入用户搜索列表"
    # `security list-keychains -d user` 每行是带缩进和引号的路径，拼回参数时要清掉。
    search_list=()
    while IFS= read -r line; do
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//')"
      if [[ -n "$line" ]]; then search_list+=("$line"); fi
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${search_list[@]}" "$dev_keychain"
  fi
  security unlock-keychain -p hax-shot-dev "$dev_keychain" >/dev/null 2>&1 || true
  # --deep 连带签 Frameworks / 插件 / Rust dylib；--preserve-metadata=entitlements 保留
  # Xcode 已经写进去的 get-task-allow / disable-library-validation（debug 需要）。
  # 不要 preserve requirements：那会把 ad-hoc 的旧 requirement 留下来。
  codesign --force --deep --sign "$identity" --keychain "$dev_keychain" \
    --preserve-metadata=entitlements,flags "$built"
  codesign --verify --deep --strict "$built" && echo "note: 签名校验通过"
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
# 显式登记到 LaunchServices：不登记的话，安装后第一次从 Finder/Dock 启动要现做一遍
# 注册，托盘图标会晚 2~3 秒才出现（用户报过“启动很慢”）。
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$install_dir/$bundle" >/dev/null 2>&1 || true
fi

if [[ -n "$zip_path" ]]; then
  mkdir -p "$(dirname "$zip_path")"
  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$install_dir/$bundle" "$zip_path"
  echo "note: 已打包 $zip_path"
fi

echo
echo "已安装: $install_dir/$bundle"
echo "签名  : $(codesign -dvv "$install_dir/$bundle" 2>&1 | grep -m1 'Authority=' || echo 'ad-hoc（无证书）')"
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

TIP

if [[ "$dev_cert" != true ]]; then
  cat <<'TIP'
注意：本次没有用固定证书（--dev-cert），是 ad-hoc 签名。ad-hoc 签名每次重新构建
都会换一个签名指纹，macOS 会认为这是“新的 app”，屏幕录制授权会失效、而且不一定
再弹窗。遇到“截图失败：未授予屏幕录制权限”时，去“系统设置 → 隐私与安全性 →
屏幕录制”把 Hax Shot 删掉再重新加一次即可。想要以后重构建不用重新授权：

  scripts/macos_dev_cert.sh --trust     # 一次：建证书并信任（会弹系统授权）
  scripts/install_macos_app.sh --dev-cert

TIP
fi
