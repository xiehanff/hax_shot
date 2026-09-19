# HaxShot

菜单栏 / 托盘常驻的截图工具：按一下快捷键，画面先冻住，再框选、标注，然后保存 PNG、复制到
剪贴板，或者丢给 AI 提取文字/翻译/解释。

- **macOS**：Apple Silicon（arm64），菜单栏应用，没有 Dock 图标；
- **Linux**：Fedora GNOME + Wayland，只保证主显示器；
- **Windows**：Windows 11 x64，提供 Setup EXE 安装包（每用户安装，不需要管理员权限）和解压即用
  的 ZIP，两者都未签名；Win10 / 多显示器 / 混合 DPI 尚未验证。

## 下载安装

到 [Releases](https://github.com/xiehanff/hax_shot/releases) 下载对应安装包：

| 平台 | 文件 | 安装 |
| --- | --- | --- |
| macOS | `HaxShot-<版本>-arm64.dmg` | 挂载后把 `HaxShot.app` 拖进“应用程序” |
| macOS（内部测试） | `HaxShot-<版本>-arm64-unsigned.dmg` | 未签名/未公证，只能自己机器上右键“打开”，别人机器会被 Gatekeeper 拦 |
| Debian / Ubuntu | `hax-shot_<版本>_amd64.deb` | `sudo apt install ./hax-shot_<版本>_amd64.deb` |
| Fedora | `hax-shot-<版本>-1.x86_64.rpm` | `sudo dnf install ./hax-shot-<版本>-1.x86_64.rpm` |
| Windows | `HaxShot-<版本>-windows-x64-setup.exe` | 双击安装，每用户安装、不需要管理员权限（见 [Windows（安装包与 ZIP 包）](#windows安装包与-zip-包)） |
| Windows（免安装） | `HaxShot-<版本>-windows-x64.zip` | 解压到一个固定目录，双击 `hax_shot.exe` |

> Windows 的两个产物从包含 Windows 适配的版本开始随 Release 发布，更早的版本里没有这些资产。
> 具体步骤见下面的 [Windows（安装包与 ZIP 包）](#windows安装包与-zip-包)。

## 第一次使用

1. 启动后不会出现主窗口，只在**菜单栏 / 托盘**出现一个小图标；
2. 点图标 → **立即截屏**；
3. macOS 第一次会弹“屏幕录制”授权：点“打开系统设置”→ 勾选 HaxShot → 回到菜单栏
   再点一次“立即截屏”。**没授权之前不会铺满全屏**，只会弹一个说明用的小窗口，随时可以关掉；
4. 画面冻住后拖拽框选，选完可以标注、复制、保存或交给 AI；`Esc` 取消。

默认快捷键：

- **macOS**：**⇧⌥Z**，启动后自动注册；
- **Linux**：**Alt+Shift+Z**（macOS 的 ⌥ 在 Linux 上就是 Alt），需要执行一次
  `/usr/share/hax-shot/install-gnome-shortcut.sh` 装进 GNOME 自定义快捷键——
  从旧版本升级上来的话重跑一次，把旧的 Alt+Z 换成新默认值。
- **Windows**：**Alt+Shift+Z**，启动后自动注册（不用手动装任何东西）。

菜单栏 / 托盘图标可能被 Bartender 这类工具收进隐藏区，所以默认就留了一个不依赖图标的入口；
可以在 **设置** 里改快捷键，也可以开关开机自启动。

## Windows（安装包与 ZIP 包）

Windows 版有两种装法，内容一样（都自带 VC++ 运行库，不需要额外安装）：

### 方式一：Setup EXE（推荐）

1. 双击 `HaxShot-<版本>-windows-x64-setup.exe`；
2. 默认装到 `%LOCALAPPDATA%\Programs\HaxShot`（每用户安装，**不需要管理员权限**，向导里可以
   改成别的目录）；开始菜单里会有 HaxShot，桌面快捷方式在向导里勾选（默认不勾）；
3. 向导最后一页可以勾「运行 HaxShot」直接启动。

升级直接跑新版本的 setup.exe：旧版本还在跑的话，安装程序会先把它关掉（托盘图标消失）再替换
文件，装完自己从开始菜单再启动一次即可。不想要了就在「设置 → 应用」里卸载，或者跑安装目录里的
`unins000.exe`。

### 方式二：ZIP（免安装）

1. 把 `HaxShot-<版本>-windows-x64.zip` 解压到一个固定目录（例如 `C:\Program Files\HaxShot`
   或 `%LOCALAPPDATA%\HaxShot`），解压完应该直接看到 `hax_shot.exe`。以后升级要覆盖同一个
   目录，所以不要解压到临时目录里；
2. 双击 `hax_shot.exe`。

### 启动之后

1. 不会出现主窗口，只在 **托盘** 出现图标（不占任务栏）；
2. 托盘图标 **左键或右键** 都能弹出菜单：立即截屏 / 设置 / 退出；
3. 默认快捷键 **Alt+Shift+Z**，首次启动自动注册；也可以在托盘菜单 →「设置」里改，
   或者在那里开关开机自启动。

**看不到托盘图标？** Windows 11 默认把新程序的图标收进任务栏的 `^`（“显示隐藏的图标”）
溢出菜单里，此时应用其实已经在运行——点开 `^`，把 HaxShot 拖到任务栏上就能常驻。
程序侧没有办法自己把图标提升出来（系统没有这个 API），这不是故障。

**未签名**：setup.exe 和 ZIP 里的 exe / dll 都没有代码签名，首次运行 Windows 会弹 SmartScreen
（“Windows 已保护你的电脑”）——点「更多信息」→「仍要运行」就能继续（装安装包和启动程序可能
各弹一次）。这是预期行为，不要把系统的安全防护关掉来装它。两个包都已经带上 VC++ 运行库，
不需要额外安装（无 VS 的干净机器上的实测还没做）。

### 日志在哪里

日志是 JSON Lines，路径固定：`%LOCALAPPDATA%\hax_shot\logs\hax_shot.log`。

```powershell
$log = "$env:LOCALAPPDATA\hax_shot\logs\hax_shot.log"

# 最后 50 条（日志是 UTF-8，不加 -Encoding UTF8 时中文会显示成乱码）
Get-Content $log -Tail 50 -Encoding UTF8

# 只看截图 / 快捷键链路（事件名是 ASCII，中文只在 message 字段里）
Get-Content $log -Encoding UTF8 |
  Select-String -Pattern 'shortcut_trigger|spawn_success|child_started|lock_busy|capture_ready|overlay_ready|failed'
```

`Select-String -Encoding` 是 PowerShell 7 才有的参数；Windows PowerShell 5.1 用上面的管道写法。

### 升级与卸载

- **安装包装的**：升级直接跑新版本 setup.exe（旧实例会被自动关掉再替换文件，不用自己先退出）；
  卸载用「设置 → 应用」里的卸载项，或安装目录里的 `unins000.exe`。卸载会删掉安装目录、开始菜单
  快捷方式和开机自启动项；
- **ZIP 装的**：先从托盘退出旧版本（确认任务管理器里没有 `hax_shot.exe` 残留），再把新 ZIP
  解压覆盖同一个目录。目录换了位置就要到设置里重新打开一次开机自启动；卸载就是托盘退出 →
  设置里关掉「开机自启动」→ 删掉解压出来的目录；
- 两种方式的自启动都只写当前用户的
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，没有系统服务、计划任务或驱动要清理；
  用户数据（日志、设置）都在 `%LOCALAPPDATA%\hax_shot\`，**卸载不会删**。

### Windows 目前不保证的部分

- 没验证过的：Windows 10、多显示器 / 副屏在左侧（负坐标）/ 混合 DPI、三屏；
- 不支持：HDR、独占全屏、DRM 受保护内容；
- 截图里不包含鼠标指针；
- 非 US 键盘布局下，符号键（`;` `[` 这类）的快捷键按 US 布局解释；字母、数字、功能键不受影响。

## 怎么用

- **框选**：拖拽画一个矩形，只截这个范围；
- **标注**：框选之后点工具条上的矩形 / 箭头 / 文字图标，在**选区内**再拖拽或点击；
  文字框可以拖四角缩放字号、拖顶部抓手移动，点它重新编辑。标注的边框、控制点这些
  **不会**出现在导出的图片里；
- **复制 / 保存**：工具条上的复制和保存按钮，保存会弹系统对话框选目录；
- **交给 AI**：提取文字 / 翻译 / 解释 / 深入理解会把**当前选区和标注合成的最终图**发给 AI；
  提取文字只把图上文字原样吐回一个代码块（右上角可一键复制），不做翻译或解释；
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

还不行就看日志，一条条往下找停在哪一层（Windows 的日志路径与命令见
[Windows（安装包与 ZIP 包）](#windows安装包与-zip-包)）：

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
- **Windows**：安装包装的用「设置 → 应用」里的卸载项，或安装目录里的 `unins000.exe`；ZIP 装的
  托盘退出 → 设置里关掉「开机自启动」→ 删掉解压出来的目录（见
  [Windows（安装包与 ZIP 包）](#windows安装包与-zip-包)）。

## 许可证

HaxShot 源代码采用 [MIT License](./LICENSE)。第三方依赖、图标与字体资产、GNOME/GStreamer/
PipeWire 组件的许可与来源见 [第三方声明](./THIRD_PARTY_NOTICES.md)。
