# HaxShot

菜单栏 / 托盘常驻的截图工具：按一下快捷键，画面先冻住，再框选、标注，然后保存 PNG、复制到
剪贴板，或者丢给 AI 翻译/解释。

- **macOS**：Apple Silicon（arm64），菜单栏应用，没有 Dock 图标；
- **Linux**：Fedora GNOME + Wayland，只保证主显示器。

## 下载安装

到 [Releases](https://github.com/xiehanff/hax_shot/releases) 下载对应安装包：

| 平台 | 文件 | 安装 |
| --- | --- | --- |
| macOS | `HaxShot-<版本>-arm64.dmg` | 挂载后把 `HaxShot.app` 拖进“应用程序” |
| macOS（内部测试） | `HaxShot-<版本>-arm64-unsigned.dmg` | 未签名/未公证，只能自己机器上右键“打开”，别人机器会被 Gatekeeper 拦 |
| Debian / Ubuntu | `hax-shot_<版本>_amd64.deb` | `sudo apt install ./hax-shot_<版本>_amd64.deb` |
| Fedora | `hax-shot-<版本>-1.x86_64.rpm` | `sudo dnf install ./hax-shot-<版本>-1.x86_64.rpm` |

## 第一次使用

1. 启动后不会出现主窗口，只在**菜单栏 / 托盘**出现一个小图标；
2. 点图标 → **立即截屏**；
3. macOS 第一次会弹“屏幕录制”授权：点“打开系统设置”→ 勾选 HaxShot → 回到菜单栏
   再点一次“立即截屏”。**没授权之前不会铺满全屏**，只会弹一个说明用的小窗口，随时可以关掉；
4. 画面冻住后拖拽框选，选完可以标注、复制、保存或交给 AI；`Esc` 取消。

macOS 默认快捷键是 **⌥⇧Z**。菜单栏图标可能被 Bartender 这类工具收进隐藏区，所以默认就留了
一个不依赖图标的入口；可以在 **设置** 里改，也可以关掉/打开开机自启动。

## 怎么用

- **框选**：拖拽画一个矩形，只截这个范围；
- **标注**：框选之后点工具条上的矩形 / 箭头 / 文字图标，在**选区内**再拖拽或点击；
  文字框可以拖四角缩放字号、拖顶部抓手移动，点它重新编辑。标注的边框、控制点这些
  **不会**出现在导出的图片里；
- **复制 / 保存**：工具条上的复制和保存按钮，保存会弹系统对话框选目录；
- **交给 AI**：翻译 / 解释 / 深入理解会把**当前选区和标注合成的最终图**发给 AI；
  之后可以继续用文字追问，也可以在设置里填 DeepSeek API Key；
- **取消**：`Esc`，或工具条上的取消按钮。

托盘菜单：立即截屏 / 设置 / 退出。设置页里能改快捷键、开关开机自启动。

## 常见问题

**按了快捷键没反应**

先排除两个最常见的：

1. **权限**：macOS 系统设置 → 隐私与安全性 → 屏幕录制，确认 HaxShot 是开的。如果开关看着是
   开的却仍提示没权限（常见于每次重新安装后），在设置页点“重置授权记录”，或手动执行
   `tccutil reset ScreenCapture com.github.xiehanff.haxShot`，然后重新授权一次；
2. **已经有截图在等着**：屏幕上有没关掉的框选浮层时，再按快捷键不会叠第二层，先 `Esc` 关掉。

还不行就看日志，一条条往下找停在哪一层（路径：`~/Library/Application Support/com.github.xiehanff.haxShot/logs/hax_shot.log`）：

```bash
LOG="$HOME/Library/Application Support/com.github.xiehanff.haxShot/logs/hax_shot.log"
grep -E 'shortcut_trigger|spawn_success|child_started|lock_busy|capture_ready|_failed' "$LOG" | tail -15
```

| 日志里看到 | 说明 |
| --- | --- |
| 只有 `shortcut_register_success`，没有 `shortcut_trigger` | 快捷键没送到：注册或系统生命周期问题 |
| 有 `shortcut_trigger`，没有 `capture_process_spawn_success` | 截图进程没起来 |
| 有 `capture_child_started` 接着 `capture_lock_busy` | 正常，已经有一层浮层在等着 |
| 什么都没有 | 程序没在跑（看菜单栏图标 / 活动监视器） |

**快捷键和别的软件冲突**

Carbon 的热键不跨进程独占，别的软件占了同一个组合时可能只有一边生效。换一个组合即可。

**睡眠唤醒后快捷键失效**

1.4.8 起会在唤醒/解锁后自动重新注册，并补做两次重试。如果仍然失效，退出重开一次一定能恢复
（新进程的注册一定是好的），并把日志留给我。

## 卸载

- **macOS**：把“应用程序”里的 `HaxShot.app` 拖进废纸篓即可；想连授权记录、开机自启动项和
  偏好设置一起清掉，用仓库里的 `scripts/uninstall_macos_app.sh`；
- **Linux**：`sudo dnf remove hax-shot` 或 `sudo apt remove hax-shot`，再删掉 GNOME 里的自定义
  快捷键（设置 → 键盘 → 自定义快捷键）。

## 许可证

HaxShot 源代码采用 [MIT License](./LICENSE)。第三方依赖、图标与字体资产、GNOME/GStreamer/
PipeWire 组件的许可与来源见 [第三方声明](./THIRD_PARTY_NOTICES.md)。

## 给开发/维护者

改代码、打包发版、排查 macOS 权限与快捷键问题，看这两份（README 只讲怎么用）：

- [`docs/development-guide.md`](./docs/development-guide.md)：代码入口、两个进程模型、macOS 适配、
  快捷键状态机、诊断日志、坑与“为什么不能那么写”、手动验证清单；
- [`docs/packaging.md`](./docs/packaging.md)：Linux DEB/RPM、macOS DMG 与签名/公证、CI 发布流程。

Rust 原生层见 [`rust/README.md`](./rust/README.md)。
