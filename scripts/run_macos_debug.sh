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
# 为什么构建完还要用本地证书重签：
#   Xcode 默认给 Debug 配置用的是 ad-hoc 签名（CODE_SIGN_IDENTITY = "-"）。ad-hoc 的
#   授权记录绑在 **cdhash** 上，而 cdhash 每次重新构建都会变 —— 表现就是「系统设置里
#   屏幕录制开关还是开的，App 却提示没权限，而且不再弹授权框」，每次改代码重建都要
#   重新授权一次。用固定的本地证书（scripts/macos_dev_cert.sh 创建）重签之后，授权
#   记录绑的是证书的 designated requirement，重建不掉（详见 docs/development-guide.md 6.2）。
#
# 用法：
#   scripts/run_macos_debug.sh            # 构建 debug、用本地证书重签、再用 open 启动
#   scripts/run_macos_debug.sh --release  # 用 release 构建
#   scripts/run_macos_debug.sh --ad-hoc   # 跳过重签（想复现 ad-hoc 的授权问题时才用）
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

mode="debug"
dev_cert=true
for arg in "$@"; do
  case "$arg" in
    --release) mode="release" ;;
    --ad-hoc) dev_cert=false ;;
    *) echo "error: 未知参数 $arg" >&2; exit 1 ;;
  esac
done

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
else
  flutter_cmd=(flutter)
fi

echo "note: 构建 ${mode}"
"${flutter_cmd[@]}" build macos "--${mode}"

case "$mode" in
  debug) app_path="$repo_root/build/macos/Build/Products/Debug/HaxShot.app" ;;
  *) app_path="$repo_root/build/macos/Build/Products/Release/HaxShot.app" ;;
esac

if [[ ! -d "$app_path" ]]; then
  echo "error: 找不到 ${app_path}" >&2
  exit 1
fi

identity="Hax Shot Dev"
dev_keychain="$HOME/Library/Keychains/hax-shot-dev.keychain-db"
if [[ "$dev_cert" == true ]]; then
  if security find-identity -v -p codesigning "$dev_keychain" 2>/dev/null | grep -q "$identity"; then
    echo "note: 用 ${identity} 重签（否则 ad-hoc 授权每次重建都失效）"
    # codesign 只在「keychain 搜索列表」里的 keychain 中找身份，理由同 install_macos_app.sh。
    if ! security list-keychains -d user | grep -qF "$dev_keychain"; then
      search_list=()
      while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//')"
        if [[ -n "$line" ]]; then search_list+=("$line"); fi
      done < <(security list-keychains -d user)
      security list-keychains -d user -s "${search_list[@]}" "$dev_keychain"
    fi
    security unlock-keychain -p hax-shot-dev "$dev_keychain" >/dev/null 2>&1 || true
    # 保留 entitlements：debug 需要 get-task-allow / JIT / disable-library-validation。
    codesign --force --deep --sign "$identity" --keychain "$dev_keychain" \
      --preserve-metadata=entitlements,flags "$app_path"
    codesign --verify --deep --strict "$app_path" && echo "note: 签名校验通过"
  else
    echo "warn: 找不到本地证书“${identity}”，本次是 ad-hoc 签名 —— 屏幕录制授权每次重建都会失效。" >&2
    echo "      先跑 scripts/macos_dev_cert.sh --trust 创建它，或加 --ad-hoc 明确跳过。" >&2
  fi
else
  echo "note: --ad-hoc：跳过重签（授权会绑 cdhash，重建即失效）"
fi

# 已经在跑的旧实例会占住 bundle，替换/重签之后必须让它退出，否则 open 只是激活旧进程。
if pgrep -x HaxShot >/dev/null 2>&1; then
  echo "note: 退出正在运行的 HaxShot"
  pkill -x HaxShot || true
  sleep 1
fi

echo "note: 用 open 启动（让 Hax Shot 成为责任进程，权限才记在它身上）"
open "$app_path"

cat <<'TIP'

它是菜单栏应用：没有 Dock 图标，只在菜单栏右侧出现一个小图标。
按 ⌥Z（或菜单栏图标 → 立即截屏）→ 首次会弹授权引导 →「打开系统设置」
→ 在“屏幕录制”里勾选 HaxShot → 回来点「我已授权，重新检查」（会自动重启抓屏进程）。

顺手的命令：
  查看权限状态（无需弹窗）：  /tmp/preflight   # 若不存在：见 docs/development-guide.md
  清掉错位的授权记录：        tccutil reset ScreenCapture com.github.xiehanff.haxShot

第一次从 ad-hoc 切到证书签名时，旧的授权记录还对不上号，需要 reset 一次再重新授权；
之后就固定绑在证书上，重建不用再授权。
TIP
