# 打包与分发

一份文档覆盖四件事：**Linux 包（DEB/RPM）**、**macOS 包（DMG + 签名/公证）**、
**Windows ZIP**、**CI 发布流程**。改打包链路前先看这里，不要新建文档。

产物命名（三平台一起看，tag 必须和 `pubspec.yaml` 对得上）：

```text
pubspec 1.5.0+1  →  tag v1.5.0
  macOS   HaxShot-1.5.0-arm64.dmg（没签名/公证时必须叫 HaxShot-1.5.0-arm64-unsigned.dmg）
  Windows HaxShot-1.5.0-windows-x64.zip
  DEB     hax-shot_1.5.0+1_amd64.deb
  RPM     hax-shot-1.5.0-1.x86_64.rpm
```

Linux 当前提供 **Fedora x86_64 RPM** 和 **Debian/Ubuntu amd64 DEB**。这是因为应用目标是 GNOME + Wayland，且截图链路依赖运行中的 Mutter ScreenCast、PipeWire、GStreamer 插件和 `wl-copy`；这些组件不适合被塞进一个“完全自包含”的 AppImage。

## Linux：本地构建安装包

准备：

- FVM，并已执行 `fvm install`；
- Rust/Cargo；
- RPM：`rpmbuild`；DEB：`dpkg-deb`；
- `patchelf`；
- Flutter Linux 构建依赖。

执行：

```bash
fvm flutter build linux --release
./scripts/build_linux_rpm.sh --skip-build
./scripts/build_linux_deb.sh --skip-build
```

或者由脚本完成 Flutter Release 构建：

```bash
./scripts/build_linux_rpm.sh
./scripts/build_linux_deb.sh
```

产物位于：

```text
build/linux/x64/release/hax-shot-<version>-<release>.<arch>.rpm
build/linux/x64/release/hax-shot_<version>_amd64.deb
```

两个脚本的安装布局一致（都来自 `packaging/hax_shot.spec` 的约定）：bundle 整体放
`/opt/hax-shot`，`/usr/bin/hax_shot` 只是转发包装，桌面入口、图标和
`install-gnome-shortcut.sh` 装到系统标准位置。

## Linux 侧在 CI 里的构建

tag 触发的 `release.yml` 用**同一套脚本**构建 DEB 和 RPM（`scripts/build_linux_deb.sh --skip-build`
/ `scripts/build_linux_rpm.sh --skip-build`），并校验两个包都带上 `libhax_shot_native.so`，
再把包同时存成 Actions artifact 和 GitHub Release 资产。完整的发布约定、签名/公证和失败处理
见下面的「发布」一节——**不要在这里另写一份流程**。

## Linux：安装和卸载

```bash
sudo dnf install ./build/linux/x64/release/hax-shot-*.rpm
# 或者
sudo apt install ./build/linux/x64/release/hax-shot_*_amd64.deb
```

两个包都不会擅自修改当前用户的 GNOME 快捷键。安装后由用户执行：

```bash
/usr/share/hax-shot/install-gnome-shortcut.sh
```

这会把 `Alt+Shift+Z` 写入当前用户的 GNOME GSettings，并指向 `/usr/bin/hax_shot --capture`。
脚本**不要 sudo**：它写的是当前用户的 gsettings 和 `~/.local/share`，sudo 会装到 root 名下。

旧版本装的是 `Alt+Z`；GNOME 不会替用户迁移已有的 gsettings，从旧版本升级上来要重跑一次这个
脚本（macOS 侧相反，宿主启动时会自动迁移历史默认值）。

卸载：

```bash
sudo dnf remove hax-shot
# 或者
sudo apt remove hax-shot
```

卸载后如需删除用户自己的快捷键配置，可再次检查 GNOME 自定义快捷键列表；系统包不会替用户清理个人 GSettings。

## 运行时依赖

两个包都不捆绑 GNOME/Mutter、GTK、PipeWire、GStreamer 和 Wayland 工具，而是在包元数据里
声明运行依赖。其中的 `keybinder3` / `libkeybinder-3.0-0` 是 `hotkey_manager_linux` 链接的
全局快捷键库，Linux 构建也需要对应的开发包（`keybinder3-devel` / `libkeybinder-3.0-dev`）。
Fedora 侧（RPM）：

```text
gtk3
glib2
libstdc++
keybinder3
gstreamer1
gstreamer1-plugins-base
gstreamer1-plugins-good
pipewire
pipewire-gstreamer
wl-clipboard
libayatana-appindicator-gtk3
```

Debian/Ubuntu 侧（DEB，`build_linux_deb.sh` 的 `Depends`）：

```text
libgtk-3-0 (或 Ubuntu 24.04 的 libgtk-3-0t64)
libglib2.0-0 (或 libglib2.0-0t64)
libstdc++6
libkeybinder-3.0-0
libgstreamer1.0-0
gstreamer1.0-plugins-base
gstreamer1.0-plugins-good
libpipewire-0.3-0
wl-clipboard
libayatana-appindicator3-1
```

GNOME AppIndicator 扩展在 RPM 里作为推荐依赖提供。目标机器还必须运行 GNOME Wayland 会话，并提供 Mutter ScreenCast D-Bus 服务和 PipeWire 用户服务。

特别注意：安装成功不代表所有桌面环境都支持 HaxShot。KDE、X11、wlroots、多显示器和没有 AppIndicator 的 GNOME 环境不在当前保证范围内。DEB 目前只在 Ubuntu 24.04（GNOME Wayland）验证过构建，未在 Debian 上实测安装。

## Rust 动态库为什么可以直接随包

Rust 不是运行时再安装的依赖。Flutter Release 构建期间，`linux/CMakeLists.txt` 会执行：

```text
cargo build --manifest-path rust/Cargo.toml --release
→ build/linux/x64/release/bundle/lib/libhax_shot_native.so
```

两个包都把整个 Flutter bundle 搬到 `/opt/hax-shot`，并通过相对 RPATH 保持：

```text
/opt/hax-shot/hax_shot                 → $ORIGIN/lib
/opt/hax-shot/lib/*.so                  → $ORIGIN
```

因此 Dart FFI 可以在安装后继续加载：

```text
/opt/hax-shot/lib/libhax_shot_native.so
```

包本身不需要携带 Rust 源码或 Cargo registry。

## Linux：发布前检查

在 Fedora/Ubuntu GNOME Wayland 机器上安装 RPM（或 DEB）后，至少验证：

```bash
rpm -q hax-shot            # 或 dpkg -l hax-shot
ldd /opt/hax-shot/hax_shot
ldd /opt/hax-shot/lib/libhax_shot_native.so
gst-inspect-1.0 pipewiresrc
gst-inspect-1.0 pngenc
command -v wl-copy
/usr/share/hax-shot/install-gnome-shortcut.sh
```

然后重新登录或等待 GNOME Shell 刷新托盘，测试：

1. 托盘图标和菜单；
2. `Alt+Shift+Z`；
3. 选区保存；
4. PNG 图片剪贴板；
5. 设置页统一配置快捷键和登录自启动。

## 当前不发布 AppImage

AppImage 可以携带 Flutter bundle 和 Rust `.so`，但不能可靠携带并隔离 GNOME/Mutter ScreenCast、PipeWire 会话、GStreamer 插件和 Wayland 剪贴板协议。因此当前只发布 RPM 和 DEB；如果未来增加 AppImage，它只能作为依赖宿主 GNOME 服务的便携包，不能承诺完全自包含。

## macOS 打包与分发

这份文档只讲**分发给别人**（不是本机自测）的链路。本机开发请用
[`development-guide.md`](./development-guide.md) 里的 `scripts/install_macos_app.sh`。

### 0. 只支持 Apple Silicon（arm64）

本项目**不支持 Intel Mac**，也不做通用二进制（universal）：

- `macos/Runner/Configs/AppInfo.xcconfig` 里 `ARCHS = arm64`，`scripts/build_macos_rust.sh`
  按 `$ARCHS` 逐架构构建 Rust dylib（当前只会走 `aarch64-apple-darwin`）；
- 产物验证：`lipo -archs /Applications/HaxShot.app/Contents/MacOS/HaxShot` 应为 `arm64`，
  `Contents/Frameworks/` 下所有框架和 `libhax_shot_native.dylib` 也都只能是 `arm64`；
- DMG 文件名固定带 `-arm64`（例如 `HaxShot-<版本>-arm64.dmg`）。

在 Intel 机器上 macOS 自己会拦下：提示“不能打开，因为此类型 Mac 不支持”，这是预期行为，
不需要我们额外做检测。

### 1. 一条命令

```bash
### 有 Developer ID 证书时自动签名
scripts/build_macos_dmg.sh

### 明确指定身份 / 并提交 Apple 公证
MACOS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  NOTARY_PROFILE=hax-shot scripts/build_macos_dmg.sh --notarize

### 只对已有产物做验收检查
scripts/build_macos_dmg.sh --verify-only

### 本机联调用的 debug 镜像（ad-hoc 签名、不公证）：
scripts/build_macos_dmg.sh --debug            # → build/macos/HaxShot-<版本>-arm64-debug.dmg
scripts/build_macos_dmg.sh --debug --install   # 再把 app 从 DMG 装进 /Applications
```

产出：

```text
build/macos/HaxShot-<version>-<arch>.dmg
```

脚本会按顺序做五件事，并在最后逐项验收：构建 → 用 Developer ID 重新签名（bundle 内先签
framework/dylib，再签 app）→ 打 DMG（含 `/Applications` 快捷方式）→ 可选公证 + staple →
验收检查。

### 2. 分发给别人的机器，缺哪一环会怎样

| 环节 | 缺了会怎样 | 谁提供 |
|---|---|---|
| Developer ID Application 签名 | Gatekeeper 报“无法验证开发者/已损坏”，用户打不开 | 付费 Apple Developer 账号里的证书 |
| 硬化运行时（`ENABLE_HARDENED_RUNTIME = YES`） | 无法通过公证 | 已在 `macos/Runner/Configs/Release.xcconfig` 里开好 |
| 公证 + staple | 首次打开需要用户手动右键→打开（新系统可能直接拒绝） | `xcrun notarytool` + keychain profile |
| bundle 内 framework/dylib 同身份签名 | library validation 拒绝加载 Rust dylib | `scripts/build_macos_rust.sh` 用 `EXPANDED_CODE_SIGN_IDENTITY` 签，脚本也会兜底重签 |

注意：**Apple Development 证书不能分发**，本机那把已经吊销；也没有可用于生产的
自签名方案——自签名证书只适合本机开发（见下文）。

### 3. 屏幕录制授权：为什么必须保持同一个签名身份

macOS 把“屏幕录制”授权绑在代码签名上：

- **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`）绑定的是构建产物指纹，每次重新构建都变 →
  系统设置里那条旧记录（开关看着是开的）和二进制对不上，既没权限也不再弹授权框。
- **Developer ID 签名**绑定的是证书 + bundle id → 用户授权一次之后，后续版本升级
  （甚至换版本号）都保留授权，不会反复要求授权。

所以正式分发的 app **必须**用 Developer ID 签名，不只是为了 Gatekeeper，也是为了升级时
不折腾用户。`tccutil reset` 那种修复手段只是给本地开发兜底的（见
`lib/features/settings/screen_capture_permission.dart`）。

### 本机开发：别用 `flutter run` 授权

`flutter run` 启动的 app 责任进程是终端，屏幕录制授权会记在终端上，HaxShot 不会出现在
系统设置列表里。开发时用：

```bash
scripts/run_macos_debug.sh            # 构建 debug、用本地证书重签、再 open（HaxShot 成为责任进程）
```

**它会顺手用本地证书重签**：Debug 配置默认是 ad-hoc（`CODE_SIGN_IDENTITY = "-"`），授权记录
绑 cdhash，改一行代码重建就失效——调权限相关功能时几乎没法用。加上
`scripts/macos_dev_cert.sh --trust` 创建的那个证书之后就固定绑在证书上，重建不用再授权。
想复现 ad-hoc 的授权问题才用 `--ad-hoc` 跳过重签。

### 本机开发怎么办

开发期是 ad-hoc 签名，会反复遇到上面的错位。当前实现按 `hax_pick` 的做法处理：

- 引导页每 750ms 轮询一次授权状态，切回前台时立刻重查；检测到已授权就自动重启抓屏进程继续；
- 引导页提供「重置授权记录」＝ `tccutil reset ScreenCapture <bundle id>`，专门解开
  “开关是开的但进程没权限、也不再弹框”的死结；
- `scripts/macos_dev_cert.sh` 可以创建一个自签名的本地证书，让开发期授权跨构建稳定。
  **仅限本机开发**：自签名证书无法公证，给别人的 app 用它仍然会被 Gatekeeper 拒绝。
  建好之后 `install_macos_app.sh --dev-cert`（release）和 `run_macos_debug.sh`（debug）
  都会自动用它重签；从 ad-hoc 切过来时先 `tccutil reset ScreenCapture
  com.github.xiehanff.haxShot` 清掉那条对不上号的旧记录，再重新授权一次即可。

### 4. 别人的 Mac 上第一次运行会经历什么

```text
1. 挂载 DMG → 拖 HaxShot.app 到“应用程序” → 打开
   （已公证：直接打开；未公证：右键→打开，或去“隐私与安全性”里放行）
2. 没有 Dock 图标！它是菜单栏应用（LSUIElement），只在菜单栏右侧出现一个小图标
3. 按 ⌥⇧Z 或点菜单栏图标 → “立即截屏”
4. 第一次会弹出自己的授权引导（小窗口，不是全屏）：
   「打开系统设置」→ 在“隐私与安全性 → 屏幕录制”勾选 HaxShot → 回到 app
   → 检测到授权后自动继续截图
5. 想换快捷键：菜单栏图标 → “设置” → 录制组合键（默认已经是 ⌥⇧Z）
6. 想用 AI：AI 面板里填 DeepSeek API Key
```

#### 升级后一定要退出旧实例

全局快捷键是**正在运行的那个实例**注册的。如果旧版本还在跑（菜单栏里那个图标），
即使你把新版本拷进 /Applications，按快捷键触发的仍然是旧实例 —— 表现就是“快捷键
截屏看起来和托盘截屏不是同一个版本”。`scripts/install_macos_app.sh` 会先 `pkill`
再替换 bundle，所以走脚本安装/升级不会踩这个坑。

### 已知会让人困惑的点

- **第 2 步**：菜单栏应用没有 Dock 图标，新用户容易以为没启动。已实现首次启动欢迎窗口
  （`lib/features/onboarding/first_run_guide.dart`，标记 `hax_shot.onboarding_seen`），
  说明图标位置、快捷键和首次授权，并带「打开设置」入口。
- **菜单栏图标可能被菜单栏管理工具藏起来**（本机就是 Bartender 把它收进隐藏区），
  所以默认快捷键 `⌥⇧Z` 是必需的兜底入口。
- **API Key 目前存在 shared_preferences（明文 plist）**。正式分发建议改存 Keychain。

### 5. 卸载

```bash
scripts/install_macos_app.sh                   # 重新安装（会先退出正在运行的旧实例）
scripts/uninstall_macos_app.sh                 # 卸载并清掉用户数据
scripts/uninstall_macos_app.sh --dry-run       # 先看会做什么
scripts/uninstall_macos_app.sh --keep-prefs    # 保留快捷键等偏好设置
scripts/uninstall_macos_app.sh --dir ~/Apps    # 应用装在别处
```

清掉的东西：运行中的进程、`<dir>/HaxShot.app`、`~/Library/LaunchAgents/<bundle id>.plist`
（含 `launchctl bootout`）、屏幕录制授权记录（`tccutil reset`）、偏好设置 plist，以及系统
生成的 `Saved Application State` / `Caches` / `HTTPStorages` 目录。开发用自签名证书和
`build/macos/` 里的构建产物不在范围里，脚本结尾会提示对应命令。

清偏好设置用的是 `defaults delete <bundle id>`，不是 `rm` 那个 plist：直接删文件会让
cfprefsd 留着坏掉的 domain，卸载后**第一次**启动会没有全局快捷键（菜单栏图标仍在，
再启动一次才自愈），原因和排查见 [开发指南 6.6](./development-guide.md)。

### 6. 发布前检查清单

```bash
scripts/generate_macos_icons.sh    # 从 assets/icons/hax_shot.svg 更新 AppIcon
scripts/build_macos_dmg.sh --notarize
```

脚本的验收项（全 ✅ 才算通畅）：

```text
app 签名完整（codesign --verify --deep --strict）
bundle 内动态库都已签名
Info.plist 是菜单栏应用（LSUIElement）
应用图标已打进 bundle（AppIcon.icns + CFBundleIconName）
DMG 能挂载且内含 HaxShot.app / Applications 快捷方式
Gatekeeper 接受 app（spctl）
DMG 已公证并 stapled
```

## Windows：ZIP 包

Windows 只发 ZIP（解压即用）：**没有安装器**（Setup EXE / MSIX 都不在计划内），也**不签名**，
产物名 `HaxShot-<版本>-windows-x64.zip`（版本取 `pubspec.yaml` 里 `+` 前的那段）。

### 1. 本地打包

前提：已经跑过 `flutter build windows --release`（脚本**只打包，不替你构建**），并且装了 VS 的
「使用 C++ 的桌面开发」工作负载（要从 `VC\Redist` 取 VC 运行库）：

```powershell
flutter build windows --release
pwsh scripts/package_windows_zip.ps1
```

脚本按顺序做五件事（对应计划 §51–§52）：

1. 拷 app-local VC 运行库：优先用 `$env:VCToolsRedistDir`，否则用 vswhere 找 VS 安装目录下的
   `VC\Redist\MSVC\<工具集>\x64\Microsoft.VC*.CRT`，把 `msvcp140.dll` / `vcruntime140.dll` /
   `vcruntime140_1.dll` 三个 x64 文件拷进 Release 目录；
2. 校验必需项（exe / Rust DLL / flutter_windows.dll / `data\app.so` / `data\icudtl.dat` /
   `data\flutter_assets` / 三个 CRT），**缺任何一个直接 throw**——`Test-Path` 打印 False 不会
   让 CI 失败，所以不能只检查不抛；
3. 盘点插件 DLL：少于 5 个就 throw（防“只打了个 exe”），并要求 `data\flutter_assets` 非空；
4. `Compress-Archive` 打包到 `build\windows\HaxShot-<版本>-windows-x64.zip`；ZIP 里是 Release
   目录的**内容**，解压后第一层直接是 `hax_shot.exe`，不套一层目录；
5. 复查 ZIP 根下确实有 `hax_shot.exe` / `hax_shot_native.dll`。

`-SkipCrt` 只是“本地想看 ZIP 里有什么”的调试开关，CI 与发布禁止使用（跳过之后 ZIP 在没装
VC 运行库的机器上起不来）。

### 2. ZIP 内容清单

下面是本机 2026-09-19 的 `flutter build windows --release` 实际产物（**以实际产物为准**，
不是手写的六项）：

```text
hax_shot.exe
hax_shot_native.dll                     ← Rust（windows/CMakeLists.txt 从 rust/target 装过来）
flutter_windows.dll
desktop_drop_plugin.dll
file_selector_windows_plugin.dll
hotkey_manager_windows_plugin.dll
irondash_engine_context_plugin.dll
screen_retriever_windows_plugin.dll
super_native_extensions.dll
super_native_extensions_plugin.dll
tray_manager_plugin.dll
url_launcher_windows_plugin.dll
window_manager_plugin.dll
data\app.so                             ← AOT
data\icudtl.dat
data\flutter_assets\…                   ← 整个目录
msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll   ← 打包脚本补进 bundle
```

### 3. VC 运行库策略：app-local

Flutter 官方 Windows 分发文档要求除了 exe/DLL/data 之外还要带 Visual C++ 运行库，所以三个
`x64` CRT 直接放进 ZIP（而不是要求用户先装「VC++ 可再发行组件」）。

- 只发 x64（Windows 版只支持 x64）；
- 少任何一个都 throw，不静默跳过；
- 开发机 / CI 装了 VS **不能**证明干净用户机能跑，必须在无 VS 环境实测一次（见下面第 5 节）。

### 4. CI job 与 artifact 命名

- `verify.yml` 已有 `windows` job（PR / main push）：`windows-latest`，`flutter analyze` +
  `cargo fmt --check` + `cargo check` + `flutter build windows --release` + bundle 完整性
  （同样缺文件 throw）。它**不跑测试**，也不上传 artifact；
- `release.yml` 的 `windows` job：**尚未落地**（计划里的 Phase 9）。目标形态是
  `needs: preflight`、跑构建 → `pwsh scripts/package_windows_zip.ps1` →
  `actions/upload-artifact@v4`（name `hax-shot-windows-${{ github.ref_name }}`，与
  `hax-shot-macos-*` 同风格，`retention-days: 30`，`if-no-files-found: error`），最后把
  `windows` 加进 `release.needs`；`workflow_dispatch` 干跑仍然只产 artifact、不发布。
  在此之前 Release 资产里只有 DMG / DEB / RPM。

### 5. 干净机器验证（发布前必须做一次）

在一台**没有装 VS、也没装过 VC++ 运行库**的 Windows 上：

1. 解压 `HaxShot-<版本>-windows-x64.zip` 到任意目录；
2. 双击 `hax_shot.exe`：托盘出现图标，不报“找不到 xxx.dll”；
3. 按 `Alt+Shift+Z` 截一次屏并复制到剪贴板。

**没做这一步之前**，README / Release 说明里都不能写“解压即用已验证”。

### 6. 升级 / 卸载 / 自启动迁移

- 升级：先退出旧 host 和任何 capture 子进程，再用新 ZIP 覆盖同一目录；
- 自启动：只写当前用户的 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，
  换目录后需要到设置里重新打开一次；系统“启动”页里的禁用开关存在 `StartupApproved`，
  应用不去改它，被禁用了只能到任务管理器恢复；
- 卸载：退出 → 关自启动 → 删目录；没有系统服务 / 计划任务 / 驱动需要清理。

## 发布：tag、版本约定与 CI

HaxShot 的发布目标是让“代码合并”和“发布安装包”分开：普通 `main` 分支 push 只更新源码、
只跑 [`verify.yml`](../.github/workflows/verify.yml) 的检查；只有推送版本 tag 时，
[`release.yml`](../.github/workflows/release.yml) 才会构建三个平台的安装包并发布
GitHub Release。

### 1. 触发规则

工作流位于：

```text
.github/workflows/release.yml
```

它只有一个触发器：

```yaml
on:
  push:
    tags:
      - 'v*'
```

因此以下操作不会发布 Release：

- `git push origin main`；
- 修改 PR；
- 手动 `workflow_dispatch` 干跑（见下文）。

补充：`verify.yml` 的 `push` 触发器带 `paths-ignore: ['pubspec.yaml']`。发布流程是先推
`release: vX.Y.Z`（只改版本号）再推 tag，这个提交不会触发 Verify——同一个 commit 由
Release 跑一遍就够，否则两个 workflow 会把它各构建一次。带代码的提交不受影响。

以下操作会触发打包：

```bash
git push origin v1.5.0
```

### 干跑（不发布）

`release.yml` 还支持 `workflow_dispatch`：构建 job（Linux、macOS）全部执行并上传
Actions artifact，但最后一步发布 Release 只在 tag push 时运行。改打包脚本或工作流
之后，先在 Actions 页面手动 Run workflow（或 `gh workflow run release.yml`）干跑一次，
确认绿了再打 tag——不要用真 tag 试错。

### 2. 版本约定

tag 必须与 `pubspec.yaml` 的应用版本匹配，但不包含构建号。工作流第一步就会检查这个关系，
不一致立刻失败，避免把错误版本上传到 Release。

| `pubspec.yaml` | Git tag | Release Assets |
|---|---|---|
| `1.5.0+1` | `v1.5.0` | `HaxShot-1.5.0-arm64.dmg`、`hax-shot_1.5.0+1_amd64.deb`、`hax-shot-1.5.0-1.x86_64.rpm` |

其中：

- `1.5.0` 是应用版本，也是 DMG 名字和 RPM 的 Version；
- `+1` 是 DEB 的完整版本（`1.5.0+1`）和 Fedora RPM 的 Release；
- RPM 在 Fedora 本机构建时会带 `.fc44`，在 CI（Ubuntu 的 rpmbuild）里没有这个发行版后缀；
- `v1.5.0` 是 GitHub Release 的 tag 和页面名称。

### 3. 发布流程

先在本地完成开发和验证：

```bash
fvm flutter analyze
fvm flutter test
fvm flutter build linux --debug
fvm flutter build linux --release
cargo fmt --manifest-path rust/Cargo.toml --check
cargo check --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml
```

确认工作树只包含本次发布内容后，先在 `pubspec.yaml` 更新版本并提交主分支：

```bash
git add .
git commit -m "release: v1.5.0"
git push origin main
```

这一步只改 `pubspec.yaml`，不会触发 `verify.yml`（见第 1 节的 `paths-ignore`）：这个
commit 马上就会被 tag 的 Release workflow 完整构建一遍，没必要再跑一次 Verify。

需要发布时，在**已经推送的**那个 commit 上创建带注释的 tag：

```bash
git tag -a v1.5.0 -m "Release v1.5.0"
git push origin v1.5.0
```

### 4. GitHub Actions 做什么

`release.yml` 分成四个 job：

| job | runner | 作用 |
|---|---|---|
| `preflight` | `ubuntu-24.04` | 校验 tag 与 `pubspec.yaml` 版本一致（会消耗 macOS 分钟数之前就失败） |
| `linux` | `ubuntu-24.04` | 构建 Linux release bundle，再打 `--skip-build` 的 DEB 和 RPM，校验两个包都带上 `libhax_shot_native.so` |
| `macos` | `macos-14`（arm64） | 校验 runner 架构，签名（可选）→ 公证（可选）→ 打 DMG，校验 app、Rust dylib 都是 arm64 |
| `release` | `ubuntu-24.04` | 汇总两个平台的产物，创建或更新 GitHub Release |

每个平台 job 还会把自己的包存一份 30 天有效的 Actions artifact，方便排查。

> Windows 不在上面的表里：它的 `windows` job（构建 + ZIP + `release.needs`）属于计划里的
> Phase 9，**尚未加进 `release.yml`**，接入方式见上面的「Windows：ZIP 包」第 4 节。

Dart/Rust 的 analyze 和 test 不在这里重复跑：它们由 `main`/PR 上的 `verify.yml` 负责
（Linux 与 macOS 两个 job），tag 应该指向已经过检查的 commit。

如果同一个 tag 的 Release 已经存在（例如补传 macOS 产物），`release` job 会用
`--clobber` 覆盖同名资产，而不会创建第二个 Release。

### 5. macOS 签名与公证（分发必需）

策略是**不允许静默发出未公证的 DMG**：

| 仓库 secret 情况 | 行为 |
|---|---|
| 没有 `MACOS_CERTIFICATE_P12` | 构建 ad-hoc DMG，文件名写成 `HaxShot-<版本>-arm64-unsigned.dmg`，并在 Release 正文顶部加一段“未签名/未公证、不能当常规安装包分发”的警告 |
| 有证书但缺 `APPLE_ID`/`APPLE_APP_PASSWORD`/`APPLE_TEAM_ID` | **macOS job 直接失败**：半配置状态不允许发布未公证的包 |
| 证书 + 公证凭据齐全 | 必须签名 + 公证 + staple（`build_macos_dmg.sh --notarize`），任何一步失败都会让 job 挂掉 |

也就是说：ad-hoc 包只能以 `-unsigned` 的内部测试包形式出现，永远不会冒充成正式安装包。
要对外分发 macOS 版本，需要在仓库 **Settings → Secrets and variables → Actions** 里配置：

| Secret | 说明 |
|---|---|
| `MACOS_SIGN_IDENTITY` | 形如 `Developer ID Application: Name (TEAMID)` |
| `MACOS_CERTIFICATE_P12` | Developer ID 证书导出成 `.p12` 后 base64 编码（`base64 -i cert.p12 \| pbcopy`） |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `MACOS_KEYCHAIN_PASSWORD` | CI 里临时 keychain 的密码，随意填 |
| `APPLE_ID` | 公证用的 Apple ID |
| `APPLE_APP_PASSWORD` | 该 Apple ID 的 app-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

配好之后，打 tag 前先干跑一次确认签名/公证链路通，再推 tag。缺证书阶段的公开版本，按
上一节「macOS 打包与分发」告知用户 DMG 只用于内部测试。

### 6. 发布后的检查

在仓库的 **Releases** 页面确认：

- Release tag 与 `pubspec.yaml` 版本一致，且不是 Draft；
- Assets 里三个文件都在：`HaxShot-<版本>-arm64.dmg`（或未签名时的
  `HaxShot-<版本>-arm64-unsigned.dmg`）、`hax-shot_<版本>_amd64.deb`、
  `hax-shot-<版本>-<release>.x86_64.rpm`；
- 如果只有 `-unsigned` DMG，Release 正文顶部应该已经有未签名警告；
- Release notes 由 `--generate-notes` 生成（会带上本次 tag 之前的 PR/commit 列表）。

验证 macOS 产物：

```bash
hdiutil attach HaxShot-1.5.0-arm64.dmg          # 能挂载且内含 HaxShot.app
lipo -archs /Volumes/HaxShot/HaxShot.app/Contents/MacOS/HaxShot   # arm64
spctl -a -vvv -t exec /Volumes/HaxShot/HaxShot.app                 # 有签名+公证时 should be accepted
```

验证 Linux 产物（Fedora GNOME Wayland / Ubuntu GNOME Wayland）：

```bash
sudo dnf install ./hax-shot-1.5.0-1.x86_64.rpm        # 或 sudo apt install ./hax-shot_1.5.0+1_amd64.deb
/usr/share/hax-shot/install-gnome-shortcut.sh
```

### 7. 失败处理

- **版本检查失败**：确认 tag 去掉 `v` 后等于 `pubspec.yaml` 中 `+` 前的版本；
- **Linux 打包失败**：本地复现 `./scripts/build_linux_deb.sh --skip-build` /
  `./scripts/build_linux_rpm.sh --skip-build`（脚本和 CI 走同一套代码）；
- **macOS 构建失败**：注意 runner 必须是 arm64，项目不支持 Intel Mac，也不做 universal；
- **签名/公证失败**：先确认证书没过期、`MACOS_SIGN_IDENTITY` 与导入的证书完全一致；
  公证凭据错误会直接在 `notarytool store-credentials` 或 submit 阶段报错；
- **Release 上传失败**：确认工作流有 `contents: write` 权限，或重跑同一个 tag 的 workflow。

需要重新上传同名安装包时，修复后重跑同一个 tag 的 workflow 即可覆盖资产（见第 4 节）。

一句话总结：**main push 只更新代码，`git push origin vX.Y.Z` 才构建 DMG/DEB/RPM 并发布
GitHub Release。**
