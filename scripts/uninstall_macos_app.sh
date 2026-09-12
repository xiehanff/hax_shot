#!/bin/bash
# 彻底卸载 Hax Shot（macOS）。
#
# 覆盖的内容：
#   1. 运行中的 Hax Shot 进程
#   2. 应用本体（默认 /Applications/hax_shot.app）
#   3. 开机自启动项 ~/Library/LaunchAgents/com.github.xiehanff.haxShot.plist（并 bootout）
#   4. 屏幕录制授权记录（tccutil reset ScreenCapture），否则系统设置里会留着一条空记录
#   5. 偏好设置（快捷键等）与系统生成的缓存/状态目录
#
# 用法：
#   scripts/uninstall_macos_app.sh                 # 卸载并清掉用户数据
#   scripts/uninstall_macos_app.sh --keep-prefs    # 保留快捷键等偏好设置
#   scripts/uninstall_macos_app.sh --dry-run       # 只打印会做什么，不动任何东西
#   scripts/uninstall_macos_app.sh --dir ~/Apps    # 应用装在别处
set -euo pipefail

bundle_id="com.github.xiehanff.haxShot"
app_name="hax_shot.app"
install_dir="/Applications"
keep_prefs=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-prefs) keep_prefs=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --dir)
      install_dir="${2:?--dir 需要参数}"
      shift 2
      ;;
    *)
      echo "error: 未知参数 $1" >&2
      exit 1
      ;;
  esac
done

run() {
  if [[ $dry_run -eq 1 ]]; then
    echo "   [dry-run] $*"
  else
    "$@"
  fi
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "   跳过（不存在）：$path"
    return
  fi
  if [[ $dry_run -eq 1 ]]; then
    echo "   [dry-run] rm -rf $path"
  else
    rm -rf "$path"
    echo "   已删除：$path"
  fi
}

echo "== 1/5 结束运行中的进程 =="
if pgrep -x hax_shot >/dev/null 2>&1; then
  run pkill -x hax_shot || true
  sleep 1
  if pgrep -x hax_shot >/dev/null 2>&1; then
    run pkill -9 -x hax_shot || true
  fi
  echo "   已结束"
else
  echo "   没有在运行"
fi

echo "== 2/5 删除应用本体 =="
remove_path "${install_dir}/${app_name}"

echo "== 3/5 移除开机自启动 =="
agent="$HOME/Library/LaunchAgents/${bundle_id}.plist"
if [[ -f "$agent" ]]; then
  run launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
  remove_path "$agent"
else
  echo "   没有自启动项"
fi

echo "== 4/5 清除屏幕录制授权记录 =="
if [[ $dry_run -eq 1 ]]; then
  echo "   [dry-run] tccutil reset ScreenCapture ${bundle_id}"
else
  tccutil reset ScreenCapture "$bundle_id" >/dev/null 2>&1 \
    && echo "   已重置" \
    || echo "   没有可重置的记录"
fi

echo "== 5/5 清理用户数据 =="
if [[ $keep_prefs -eq 1 ]]; then
  echo "   --keep-prefs：保留偏好设置"
else
  # 必须走 defaults delete（cfprefsd API），不能直接 rm plist：直接删文件会让 cfprefsd
  # 留着坏掉的 domain，下一次启动的 SharedPreferences 调用会一直不返回，表现出来就是
  # 那次启动没有全局快捷键（菜单能用）。见 docs/development-guide.md 6.6。
  if [[ $dry_run -eq 1 ]]; then
    echo "   [dry-run] defaults delete $bundle_id"
  else
    if defaults delete "$bundle_id" >/dev/null 2>&1; then
      echo "   已删除偏好设置：$bundle_id"
    else
      echo "   跳过（不存在）：偏好设置 $bundle_id"
    fi
  fi
  # 系统给应用生成的缓存/状态目录（不一定存在，存在才删）。
  remove_path "$HOME/Library/Saved Application State/${bundle_id}.savedState"
  remove_path "$HOME/Library/Caches/${bundle_id}"
  remove_path "$HOME/Library/HTTPStorages/${bundle_id}"
fi

echo
if [[ $dry_run -eq 1 ]]; then
  echo "以上是 dry-run 结果，未做任何修改。"
else
  echo "卸载完成。"
fi
cat <<'TIP'

另外这些不在本脚本范围内：
  - 开发用自签名证书（如果你建过）：scripts/macos_dev_cert.sh --delete
  - 构建产物与 DMG：build/macos/
  - 开发用临时截图：/var/folders/.../T/hax-shot-*.png
TIP
