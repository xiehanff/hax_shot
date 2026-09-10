#!/bin/bash
# 把 Rust 原生库编进 macOS app bundle。
#
# 由 Xcode 的 “Build Rust Native Library” 脚本阶段调用。Debug 配置对应 cargo
# 的 dev profile，Release/Profile 配置对应 cargo 的 release profile，这样
# `flutter run -d macos` 不会因为每次都做 release 编译而变慢。
set -euo pipefail

rust_dir="${SRCROOT}/../rust"
if [[ "${CONFIGURATION:-Release}" == "Debug" ]]; then
  profile="debug"
  profile_flag=""
else
  profile="release"
  profile_flag="--release"
fi

# 只做 Apple Silicon：不做 universal、不 lipo（项目不支持 Intel）。
# ARCHS 由 Xcode 传入，可能多于一项；取第一项，保证 dylib 和主程序同架构。
arch="${ARCHS:-}"
arch="${arch%% *}"
arch="${arch:-$(uname -m)}"
case "${arch}" in
  arm64) rust_target="aarch64-apple-darwin" ;;
  x86_64) rust_target="x86_64-apple-darwin" ;;
  *)
    echo "error: 未知架构 ${arch}" >&2
    exit 1
    ;;
esac

resolve_cargo() {
  if [[ -n "${CARGO:-}" && -x "${CARGO}" ]]; then
    echo "${CARGO}"
    return 0
  fi
  local candidate
  for candidate in \
    "${HOME}/.cargo/bin/cargo" \
    /opt/homebrew/bin/cargo \
    /usr/local/bin/cargo; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

if ! cargo_bin="$(resolve_cargo)"; then
  echo "error: 找不到 cargo。macOS 版本需要 Rust 工具链，请先执行：curl https://sh.rustup.rs -sSf | sh" >&2
  exit 1
fi

# Xcode 的脚本环境里 PATH 很干净，cargo 需要能找到 rustc 和链接器。
export PATH="$(dirname "${cargo_bin}"):${PATH}"

echo "note: building hax_shot_native (${profile}, ${rust_target})"
"${cargo_bin}" build --manifest-path "${rust_dir}/Cargo.toml" \
  --target "${rust_target}" ${profile_flag}

slice="${rust_dir}/target/${rust_target}/${profile}/libhax_shot_native.dylib"
if [[ ! -f "${slice}" ]]; then
  echo "error: Rust 没有产出 ${slice}" >&2
  exit 1
fi

frameworks_dir="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${frameworks_dir}"
dylib="${frameworks_dir}/libhax_shot_native.dylib"
cp -f "${slice}" "${dylib}"

# 加载未签名的动态库会被 Hardened Runtime 的 library validation 拒绝，
# 因此这里用和 app 相同的身份给 dylib 单独签名。
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${dylib}"
fi
