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
# 这样构建脚本可以非交互地签名。
#
# 还必须把证书标成“信任用于代码签名”一次，否则 `codesign --sign "Hax Shot Dev"`
# 会报 “The specified item could not be found in the keychain.”：自签名证书默认
# 是 CSSMERR_TP_NOT_TRUSTED，`security find-identity -v` 里根本不算一个有效身份。
# 这一步会弹一次系统授权（要输密码 / Touch ID），所以不能替你做，见下面的 --trust。
#
# 用法：
#   scripts/macos_dev_cert.sh            # 没有就创建，有就打印信息 + 信任状态
#   scripts/macos_dev_cert.sh --trust    # 创建后顺手写入“信任用于代码签名”（会弹授权）
#   scripts/macos_dev_cert.sh --delete   # 删除证书和 keychain
#
# 安全提示：--trust 会往你的用户信任设置里加一条“代码签名信任”，这台机器上任何
# 能拿到该私钥（keychain 密码固定为 hax-shot-dev）的东西都能签出被信任的代码。
# 只在本机开发用；不需要了就 `--delete` 并删掉信任项（钥匙串访问 → 证书 → 信任）。
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

trust_cert() {
  local cert_pem="$1"
  echo "note: 写入“信任用于代码签名”（会弹一次系统授权）"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$cert_pem"
}

# 已经有证书：报告信任状态；--trust 时补上信任。
if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -q "$identity_name"; then
  if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -q "$identity_name"; then
    echo "证书已存在且可用于签名：${identity_name}"
    security find-identity -v -p codesigning "$keychain"
    exit 0
  fi
  echo "证书已存在，但**没有被信任**，codesign 用不了它："
  security find-identity -p codesigning "$keychain" | sed -n '1,4p'
  if [[ "${1:-}" == "--trust" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    security find-certificate -c "$identity_name" -p -k "$keychain" > "$tmp/cert.pem"
    trust_cert "$tmp/cert.pem"
    security find-identity -v -p codesigning "$keychain"
    exit 0
  fi
  cat <<TIP

下一步（二选一）：
  scripts/macos_dev_cert.sh --trust     # 由脚本执行，会弹系统授权
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" <导出的证书>

做完后跑 security find-identity -v -p codesigning "$keychain"，应该能列出 ${identity_name}。
TIP
  exit 1
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

# OpenSSL 3（Homebrew 默认）导出的 PKCS#12 用的是 AES-256 + SHA-256，macOS 的
# `security import` 会报 “MAC verification failed during PKCS12 import”。加 `-legacy`
# 走旧算法才能被读进来；LibreSSL（/usr/bin/openssl）没有 `-legacy`，但它的默认算法
# 本来就是兼容的，所以失败时回退到普通导出。
if ! openssl pkcs12 -export -legacy \
  -inkey "$tmp_dir/key.pem" -in "$tmp_dir/cert.pem" \
  -name "$identity_name" -out "$tmp_dir/cert.p12" \
  -passout "pass:$password" >/dev/null 2>&1; then
  openssl pkcs12 -export \
    -inkey "$tmp_dir/key.pem" -in "$tmp_dir/cert.pem" \
    -name "$identity_name" -out "$tmp_dir/cert.p12" \
    -passout "pass:$password" >/dev/null 2>&1
fi

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

echo "已导入：$keychain"
if [[ "${1:-}" == "--trust" ]]; then
  trust_cert "$tmp_dir/cert.pem"
fi

if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -q "$identity_name"; then
  security find-identity -v -p codesigning "$keychain"
  echo
  echo "可以用它构建了： scripts/install_macos_app.sh --dev-cert"
else
  security find-identity -p codesigning "$keychain" | sed -n '1,4p'
  cat <<TIP

证书已导入但还没被信任（codesign 现在用不了它）。执行：

  scripts/macos_dev_cert.sh --trust

（会弹一次系统授权；之后 `security find-identity -v -p codesigning "$keychain"` 就能列出它）
然后用它构建： scripts/install_macos_app.sh --dev-cert
TIP
fi
