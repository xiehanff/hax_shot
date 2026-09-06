#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
skip_build=false

if [[ "${1:-}" == "--skip-build" ]]; then
  skip_build=true
fi

full_version="$(sed -n 's/^version:[[:space:]]*//p' "$repo_root/pubspec.yaml" | head -n 1)"
if [[ -z "$full_version" ]]; then
  printf 'Missing version in pubspec.yaml\n' >&2
  exit 1
fi

app_version="${full_version%%+*}"
if [[ "$full_version" == *+* ]]; then
  app_release="${full_version##*+}"
else
  app_release=1
fi

bundle_dir="$repo_root/build/linux/x64/release/bundle"
rpm_output_dir="$repo_root/build/linux/x64/release"

if [[ "$skip_build" == false ]]; then
  if ! command -v fvm >/dev/null 2>&1; then
    printf 'fvm is required; run: fvm install\n' >&2
    exit 1
  fi
  fvm flutter build linux --release
fi

if [[ ! -x "$bundle_dir/hax_shot" ]]; then
  printf 'Linux release bundle not found: %s\n' "$bundle_dir" >&2
  printf 'Run fvm flutter build linux --release first.\n' >&2
  exit 1
fi

if [[ ! -f "$bundle_dir/lib/libhax_shot_native.so" ]]; then
  printf 'Rust native library not found in bundle: %s\n' \
    "$bundle_dir/lib/libhax_shot_native.so" >&2
  exit 1
fi

for command_name in rpmbuild patchelf tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '%s is required to build the RPM package\n' "$command_name" >&2
    exit 1
  fi
done

rpm_top="$(mktemp -d)"
trap 'rm -rf "$rpm_top"' EXIT
mkdir -p "$rpm_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

tar -C "$(dirname "$bundle_dir")" \
  -czf "$rpm_top/SOURCES/hax-shot-bundle.tar.gz" bundle
tar -C "$repo_root/linux/icons" \
  -czf "$rpm_top/SOURCES/hax-shot-icons.tar.gz" hicolor
cp "$repo_root/packaging/hax_shot.desktop" \
  "$rpm_top/SOURCES/com.github.xiehanff.hax_shot.desktop"
cp "$repo_root/scripts/install-gnome-shortcut.sh" \
  "$rpm_top/SOURCES/install-gnome-shortcut.sh"
cp "$repo_root/LICENSE" "$rpm_top/SOURCES/LICENSE"
cp "$repo_root/README.md" "$rpm_top/SOURCES/README.md"
cp "$repo_root/THIRD_PARTY_NOTICES.md" \
  "$rpm_top/SOURCES/THIRD_PARTY_NOTICES.md"

# --nodeps keeps the builder usable on Ubuntu/CI hosts where Fedora runtime
# package names are not present in the local RPM database. The generated RPM
# still contains the Requires metadata declared in the spec.
rpmbuild \
  --nodeps \
  --define "_topdir $rpm_top" \
  --define "app_version $app_version" \
  --define "app_release $app_release" \
  -bb "$repo_root/packaging/hax_shot.spec"

rpm_artifact="$(find "$rpm_top/RPMS" -type f \
  -name "hax-shot-${app_version}-${app_release}.*.rpm" -print -quit)"
if [[ -z "$rpm_artifact" ]]; then
  printf 'rpmbuild completed without an RPM artifact\n' >&2
  exit 1
fi

mkdir -p "$rpm_output_dir"
release_rpm="$rpm_output_dir/$(basename "$rpm_artifact")"
cp -f "$rpm_artifact" "$release_rpm"
printf 'RPM release package: %s\n' "$release_rpm"
