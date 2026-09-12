#!/bin/bash
# 构建可分发给别人的 macOS DMG，并逐项验收分发链路是否通畅。
#
# 分发给别人的机器上，下面每一环缺了都会被 Gatekeeper 拦：
#   1. Developer ID Application 证书签名（需要付费 Apple Developer 账号；
#      Apple Development 证书只能本机调试，不能分发）
#   2. 硬化运行时（Release.xcconfig 里的 ENABLE_HARDENED_RUNTIME = YES）
#   3. 公证 notarize + staple（需要 notarytool 的 keychain profile）
#   4. bundle 内所有第三方 framework 和 Rust dylib 都用同一个身份签名
#
# 用法：
#   scripts/build_macos_dmg.sh                    # 自动找 Developer ID；找不到就产出 ad-hoc DMG（仅内部测试）
#   MACOS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build_macos_dmg.sh
#   NOTARY_PROFILE=hax-shot scripts/build_macos_dmg.sh --notarize
#   scripts/build_macos_dmg.sh --debug            # 打 debug 包（本机联调用，ad-hoc 签名、不公证）
#   scripts/build_macos_dmg.sh --debug --install   # 再挂载 DMG 把 app 装进 /Applications
#   scripts/build_macos_dmg.sh --verify-only      # 只对已有的 app/DMG 做验收检查
#
# --debug 与 --install 的说明：
#   debug 包**故意不换 Developer ID、也不公证**：debug 需要 get-task-allow/JIT，
#   hardened runtime 与公证对它没有意义，产物也只用于本机/内部联调（别人机器上会被
#   Gatekeeper 拦，这是预期）。DMG 名字带 -debug 后缀，不和 release 分发镜像混淆。
#   --install 会先退出正在运行的实例，再把 app 从 DMG 拷到 /Applications 并登记
#   LaunchServices（托盘宿主是常驻进程，替换前必须退出）。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_name="hax_shot"
bundle_name="hax_shot.app"
notarize=0
verify_only=0
build_mode="release"
install_app=0
install_dir="/Applications"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) notarize=1; shift ;;
    --verify-only) verify_only=1; shift ;;
    --debug) build_mode="debug"; shift ;;
    --install) install_app=1; shift ;;
    --dir)
      install_dir="${2:?--dir 需要参数}"
      shift 2
      ;;
    *) echo "error: 未知参数 $1" >&2; exit 1 ;;
  esac
done

if [[ "$build_mode" == "debug" && $notarize -eq 1 ]]; then
  echo "error: --debug 不能和 --notarize 一起用（debug 包不公证）" >&2
  exit 1
fi

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
else
  flutter_cmd=(flutter)
fi

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1 | cut -d+ -f1)"
arch="$(uname -m)"
if [[ "$build_mode" == "debug" ]]; then
  product_dir="Debug"
  dmg_suffix="-debug"
  entitlements="$repo_root/macos/Runner/DebugProfile.entitlements"
else
  product_dir="Release"
  dmg_suffix=""
  entitlements="$repo_root/macos/Runner/Release.entitlements"
fi
products_dir="$repo_root/build/macos/Build/Products/$product_dir"
app_path="$products_dir/$bundle_name"
dmg_path="$repo_root/build/macos/HaxShot-${version}-${arch}${dmg_suffix}.dmg"

if [[ $verify_only -eq 0 ]]; then
  echo "== 1/5 构建 ${build_mode} =="
  "${flutter_cmd[@]}" build macos "--${build_mode}"
fi

if [[ ! -d "$app_path" ]]; then
  echo "error: 找不到 $app_path" >&2
  exit 1
fi

# ---------------------------------------------------------------- 签名身份
if [[ "$build_mode" == "debug" ]]; then
  # debug 故意不换 Developer ID、不公证：需要 get-task-allow/JIT，只用于本机联调。
  echo "== 2/5 保持 Xcode 的 ad-hoc 签名（debug 不换 Developer ID）=="
  echo "   debug 构建需要 get-task-allow/JIT，hardened runtime 与公证对它没有意义；"
  echo "   这份 DMG 只用于本机/内部联调，拿到别人机器上会被 Gatekeeper 拦（预期）。"
  sign_identity=""
else
  sign_identity="${MACOS_SIGN_IDENTITY:-}"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -1
    )"
  fi
fi

signed_with_developer_id=0
if [[ "$build_mode" == "debug" ]]; then
  : # 上面已经打过 debug 的说明，这里不再重复打印“跳过 Developer ID”
elif [[ -n "$sign_identity" ]]; then
  signed_with_developer_id=1
  echo "== 2/5 用 Developer ID 重新签名 =="
  echo "   身份：$sign_identity"
  # 先签 bundle 内部的动态库和 framework，最后签 app；顺序反了 app 的封条会被破坏。
  while IFS= read -r -d '' item; do
    codesign --force --options runtime --timestamp \
      --sign "$sign_identity" "$item"
  done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 \
             \( -name "*.framework" -o -name "*.dylib" \) -print0)
  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" \
    --sign "$sign_identity" "$app_path"
else
  echo "== 2/5 跳过 Developer ID 签名 =="
  echo "   没有找到 Developer ID Application 证书，当前产物是 ad-hoc 签名。"
  echo "   → 这样的 DMG 拿到别人的 Mac 上会被 Gatekeeper 拒绝（“无法验证开发者”），"
  echo "     只能本机/内部自测。要正式分发需要付费 Apple Developer 账号里的"
  echo "     “Developer ID Application” 证书。"
fi

# ---------------------------------------------------------------- DMG
echo "== 3/5 打包 DMG =="
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg_path"
hdiutil create -volname "Hax Shot" -srcfolder "$staging" \
  -ov -format UDZO "$dmg_path" >/dev/null
echo "   $dmg_path"

# ---------------------------------------------------------------- 公证
if [[ $notarize -eq 1 ]]; then
  echo "== 4/5 公证 =="
  if [[ $signed_with_developer_id -eq 0 ]]; then
    echo "error: 没有 Developer ID 签名，无法公证" >&2
    exit 1
  fi
  profile="${NOTARY_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    echo "error: 公证需要 NOTARY_PROFILE（先执行一次：xcrun notarytool store-credentials <name>）" >&2
    exit 1
  fi
  xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
else
  echo "== 4/5 跳过公证 =="
  echo "   加 --notarize 并在 NOTARY_PROFILE 里指定 keychain profile 才会提交 Apple 公证。"
fi

# ---------------------------------------------------------------- 验收
echo "== 5/5 验收检查 =="
status_ok=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "   ✅ $label"
  else
    echo "   ❌ $label"
    status_ok=1
  fi
}

check "app 签名完整（codesign --verify --deep --strict）" \
  codesign --verify --deep --strict --verbose=2 "$app_path"
# 逐个验证 bundle 内的动态库（对目录做 --deep 不算有效检查）。
unsigned=0
while IFS= read -r -d '' item; do
  codesign --verify --strict "$item" >/dev/null 2>&1 || unsigned=$((unsigned + 1))
done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 \
           \( -name "*.framework" -o -name "*.dylib" \) -print0)
check "bundle 内动态库都已签名（未签名数=${unsigned}）" test "$unsigned" -eq 0
check "Info.plist 是菜单栏应用（LSUIElement）" \
  /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$app_path/Contents/Info.plist"
check "应用图标已打进 bundle（AppIcon.icns + CFBundleIconName）" \
  bash -c "test -f \"$app_path/Contents/Resources/AppIcon.icns\" && /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \"$app_path/Contents/Info.plist\" >/dev/null"
echo "   图标：$(du -h "$app_path/Contents/Resources/AppIcon.icns" | cut -f1)"
# DMG 挂载检查：确认里面确实是 app + /Applications 链接。
mount_point="$(mktemp -d)"
if hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null 2>&1; then
  check "DMG 能挂载且内含 ${bundle_name}" test -d "$mount_point/$bundle_name"
  check "DMG 内含 /Applications 快捷方式" test -L "$mount_point/Applications"
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
else
  echo "   ❌ DMG 挂载失败"
  status_ok=1
fi
rmdir "$mount_point" 2>/dev/null || true

authority="$(codesign -dv "$app_path" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "   签名身份：${authority:-<无>}"
if [[ $signed_with_developer_id -eq 1 ]]; then
  check "Gatekeeper 接受 app（spctl）" spctl -a -vvv -t exec "$app_path"
  check "DMG 已公证并 stapled" xcrun stapler validate "$dmg_path"
elif [[ "$build_mode" == "debug" ]]; then
  echo "   ⚠️  debug 包是 ad-hoc 签名：spctl/公证不适用（预期）；这份镜像只用于本机联调"
else
  echo "   ⚠️  ad-hoc 签名：spctl/公证 无法通过，这是预期结果（换别人机器需要 Developer ID）"
fi

if [[ $install_app -eq 1 ]]; then
  echo "== 安装到 $install_dir =="
  if [[ $status_ok -ne 0 ]]; then
    echo "error: 验收没通过，先不安装" >&2
    exit 1
  fi
  # 托盘宿主是常驻进程，会占住 bundle，替换前必须先退出。
  if pgrep -x "$app_name" >/dev/null 2>&1; then
    echo "   note: 退出正在运行的 $app_name"
    pkill -x "$app_name" || true
    sleep 1
  fi
  install_mount="$(mktemp -d)"
  hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$install_mount" >/dev/null
  mkdir -p "$install_dir"
  rm -rf "${install_dir:?}/$bundle_name"
  ditto "$install_mount/$bundle_name" "$install_dir/$bundle_name"
  hdiutil detach "$install_mount" >/dev/null 2>&1 || true
  rmdir "$install_mount" 2>/dev/null || true
  touch "$install_dir/$bundle_name"
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$install_dir/$bundle_name" >/dev/null 2>&1 || true
  fi
  echo "   已安装：$install_dir/$bundle_name"
  echo "   运行：open -a $install_dir/$bundle_name"
fi

echo
if [[ $status_ok -eq 0 ]]; then
  if [[ "$build_mode" == "debug" ]]; then
    echo "debug 镜像与安装检查通过：$dmg_path"
    echo "（本机联调用；分发仍需 Developer ID 签名 + 公证，见 docs/macos-distribution.md）"
  else
    echo "分发链路检查通过：$dmg_path"
  fi
else
  echo "分发链路仍有问题，见上面的 ❌。"
  exit 1
fi
