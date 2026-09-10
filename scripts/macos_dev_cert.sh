#!/bin/bash
# 创建（或复用）一个本地自签名代码签名证书，用于 Hax Shot 的 macOS 本地构建。
#
# 为什么需要它：
#   macOS 的“屏幕录制”授权绑在代码签名上。ad-hoc 签名没有证书，绑定的是构建产物
#   指纹（cdhash），每次重新构建都会变 → 系统设置里那条旧记录和新二进制对不上：
#   开关看着是开的，当前进程却没权限、而且因为列表里已有记录也不再弹授权框。
#   用一个固定证书签名后，授权绑的是「bundle id + 证书」，构建多少次都不用重新授权。
#
# 证书放在一个**独立的 keychain** 里（不动你的登录钥匙串），密码固定为 dev 用口令，
# 这样构建脚本可以非交互地签名。这个证书没有被系统信任，只用于本地开发。
#
# 用法：
#   scripts/macos_dev_cert.sh            # 没有就创建，有就打印信息
#   scripts/macos_dev_cert.sh --delete   # 删除证书和 keychain
#
# 注意：**这个证书不能用于分发**。要发给别人必须用 Apple Developer 账号里的
# “Developer ID Application” 证书并公证，见 docs/macos-distribution.md。
set -euo pipefail

identity_name="Hax Shot Dev"
keychain="$HOME/Library/Keychains/hax-shot-dev.keychain-db"
password="hax-shot-dev"

if [[ "${1:-}" == "--delete" ]]; then
  security delete-keychain "$keychain" 2>/dev/null && echo "已删除 $keychain" || echo "keychain 不存在"
  exit 0
fi

if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -q "$identity_name"; then
  echo "证书已存在：${identity_name}"
  security find-identity -v -p codesigning "$keychain"
  exit 0
fi

echo "note: 创建自签名代码签名证书 ${identity_name}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$tmp_dir/key.pem" -out "$tmp_dir/cert.pem" \
  -subj "/CN=$identity_name/O=Hax Shot/C=CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$tmp_dir/key.pem" -in "$tmp_dir/cert.pem" \
  -name "$identity_name" -out "$tmp_dir/cert.p12" \
  -passout "pass:$password" >/dev/null 2>&1

if [[ ! -f "$keychain" ]]; then
  security create-keychain -p "$password" "$keychain"
fi
security unlock-keychain -p "$password" "$keychain"
# -A 允许任意程序使用这把私钥，set-key-partition-list 让 codesign 不再弹框。
security import "$tmp_dir/cert.p12" -k "$keychain" -P "$password" \
  -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$password" "$keychain" >/dev/null 2>&1
# 6 小时自动锁定，避免长时间开发中签名失败。
security set-keychain-settings -lut 21600 "$keychain"

echo "已创建：$keychain"
security find-identity -v -p codesigning "$keychain"
