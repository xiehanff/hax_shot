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
#   scripts/build_macos_dmg.sh --verify-only      # 只对已有的 app/DMG 做验收检查
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_name="hax_shot"
bundle_name="hax_shot.app"
notarize=0
verify_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) notarize=1; shift ;;
    --verify-only) verify_only=1; shift ;;
    *) echo "error: 未知参数 $1" >&2; exit 1 ;;
  esac
done

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
else
  flutter_cmd=(flutter)
fi

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1 | cut -d+ -f1)"
arch="$(uname -m)"
release_dir="$repo_root/build/macos/Build/Products/Release"
app_path="$release_dir/$bundle_name"
dmg_path="$repo_root/build/macos/HaxShot-${version}-${arch}.dmg"
entitlements="$repo_root/macos/Runner/Release.entitlements"

if [[ $verify_only -eq 0 ]]; then
  echo "== 1/5 构建 release =="
  "${flutter_cmd[@]}" build macos --release
fi

if [[ ! -d "$app_path" ]]; then
  echo "error: 找不到 $app_path" >&2
  exit 1
fi

# ---------------------------------------------------------------- 签名身份
sign_identity="${MACOS_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
      | head -1
  )"
fi

signed_with_developer_id=0
if [[ -n "$sign_identity" ]]; then
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
else
  echo "   ⚠️  ad-hoc 签名：spctl/公证 无法通过，这是预期结果（换别人机器需要 Developer ID）"
fi

echo
if [[ $status_ok -eq 0 ]]; then
  echo "分发链路检查通过：$dmg_path"
else
  echo "分发链路仍有问题，见上面的 ❌。"
  exit 1
fi
