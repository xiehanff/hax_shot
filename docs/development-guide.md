# Hax Shot 当前实现与后续开发指南

> 这份文档记录的是**当前代码已经实现的行为**，不是最初的设计草案。后续 Agent 开始改 UI、截图流程或 Linux 集成前，应先读本文件，再读 [`reference-decisions.md`](./reference-decisions.md) 和 [`icon-and-tray.md`](./icon-and-tray.md)。

## 0. 开发工具链

项目使用 FVM 固定 Flutter SDK：

```text
Flutter 3.44.8
Dart 3.12.2
```

首次准备或切换 SDK：

```bash
fvm install
fvm use 3.44.8
fvm flutter --version
```

后续所有 Flutter 命令都使用 `fvm flutter`，不要直接调用系统 Flutter。

## 1. 先记住产品边界

Hax Shot 是一个 **tray-only** 应用：普通进程没有主应用窗口，只有托盘图标（Linux GNOME 托盘 / macOS 菜单栏）和托盘菜单。

托盘菜单目前只有：

```text
立即截屏
设置
退出
```

**首次启动**会弹一次欢迎窗口（`lib/features/onboarding/first_run_guide.dart`，560×460）：
托盘/菜单栏应用启动后屏幕上什么都不出现，新用户会以为没启动；欢迎页说明图标在哪、
快捷键是什么、首次截图会要屏幕录制权限。标记存在 shared_preferences 的
`hax_shot.onboarding_seen`（`FirstRunOnboarding`，按 hax_pick 的做法在**展示时**就写入，
避免用户刚看到就退出后每次启动都弹）。托盘菜单先建好再弹欢迎页，这样欢迎页失败也不影响入口。

“设置”会临时显示一个设置窗口，而不是打开外部控制中心。设置窗口展示当前 GNOME 快捷键，右侧 `×` 清空快捷键，点击“录制新的快捷键”后聚焦键盘录制区域；按下带修饰键的组合键后立即写回 GNOME GSettings，按 `Esc` 取消录制。设置页还提供基于 XDG autostart 的“开机自启动”开关。关闭设置窗口后，宿主仍回到纯托盘状态。

截图流程是：

```text
Alt+Z / 托盘“立即截屏”
    ↓
启动一个新的 hax_shot --capture 进程
    ↓
窗口保持隐藏，Rust 通过 Mutter ScreenCast + PipeWire 获取一帧冻结画面
    ↓
显示 Flutter 全屏、置顶、不可进入任务栏的框选界面
    ↓
拖拽选区
    ↓
同一张冻结图裁剪
    ├── 保存 PNG
    ├── 复制 image/png 到 Wayland 剪贴板
    ├── 点击矩形/箭头工具后，在截图选区内继续拖拽绘制标注
    ├── 点击文字工具后，在截图选区内单击并输入文字；已有文字可再次点击编辑
    ├── 四角缩放、顶部抓手移动、关闭按钮删除；点击其他区域创建新的文字框
    ├── 保存/复制带标注的最终 PNG
    └── Esc 取消
```

这里有一个必须保持的认知：**`--capture` 进程不是先显示黑窗口再截图，而是先在隐藏窗口状态下获取冻结帧，再显示框选 UI。** 如果顺序反过来，ScreenCast 会把自己的黑色遮罩或 Flutter UI 捕获进去。

## 2. 关键入口和职责

| 文件 | 职责 | 修改时的注意事项 |
|---|---|---|
| `lib/main.dart` | 解析 `--capture`，配置窗口，非捕获分支取单实例锁 | `skipTaskbar` 必须保持为 `true`；捕获进程必须先隐藏、且不能调 `SingleInstanceGuard` |
| `lib/app.dart` | tray-only 宿主、快捷键设置页、菜单、启动子进程 | 不要重新添加主应用窗口；设置页是按需显示的临时窗口；菜单截图通过 `Platform.resolvedExecutable --capture` 启动独立进程；`_quit()` 里要 `release()` 单实例锁 |
| `lib/features/app/single_instance_guard.dart` | 托盘宿主单实例保护 | 只在宿主进程用；判定存活必须同时看 PID 和 command name（PID 会被复用）；拿不到锁文件时不能阻止启动 |
| `lib/hax_colors.dart` | 品牌色 `#F8C800` 和 `haxAccentTheme()` | 只包在授权引导和设置页外层；改色值要同步这两处 `Theme(data: haxAccentTheme(...))` |
| `lib/features/settings/shortcut_settings_page.dart` | 快捷键录制、开机自启动开关 | 快捷键通过 `gsettings` 写入，启动项通过 `AutostartService` 写入当前用户 XDG 配置 |
| `lib/features/capture/capture_page.dart` | 冻结图加载、框选、保存、复制 | `_capture()` 完成前不要显示捕获窗口；保存/复制使用同一份裁剪逻辑 |
| `lib/features/capture/capture_toolbar.dart` | 磨砂玻璃工具条、HugeIcons 图标和标注工具 | 保持全圆角、纯白图标、BackdropFilter；矩形/箭头/文字工具通过 callback 切换，颜色由 CapturePage 持有并用于预览和最终 PNG |
| `lib/features/capture/screenshot_canvas.dart` | 图片适配、遮罩、选区和矩形/箭头/文字绘制、point→pixel 映射 | `ScreenshotLayout` 的坐标是 Flutter logical pixels，最终裁剪和标注导出是物理像素 |
| `lib/native/native_bridge.dart` | Dart FFI 封装 | 不在这里执行 DBus 或 `wl-copy`，这些都属于 Rust 原生层 |
| `rust/src/lib.rs` | Mutter ScreenCast、GStreamer、`wl-copy`、C ABI | 不要悄悄回退到 Screenshot Portal，否则会重新出现 GNOME 快门声 |
| `linux/runner/my_application.cc` | GTK 窗口、应用 ID、开发桌面项 | Dart 负责显示/隐藏；不要恢复旧的 first-frame 自动显示逻辑 |
| `linux/CMakeLists.txt` | Flutter bundle、Rust 库、desktop 文件和 hicolor 图标安装 | Rust 动态库和系统 GStreamer 插件是两套不同依赖 |
| `scripts/install-gnome-shortcut.sh` | 安装 `Alt+Z` 和用户 desktop/icon | 改快捷键或图标后要重新运行此脚本 |

## 3. 两个进程模型

### 3.1 普通托盘宿主

执行：

```bash
fvm flutter run -d linux
```

或直接运行 bundle：

```bash
build/linux/x64/release/bundle/hax_shot
```

这个进程：

- `skipTaskbar: true`；
- 不显示窗口；
- 初始化 `tray_manager`；
- 通过 AppIndicator 注册 GNOME 托盘图标；
- 菜单中的“立即截屏”启动独立的 `--capture` 子进程；
- 菜单中的“设置”显示 `ShortcutSettingsPage`；
- 设置页通过 `gsettings` 读取 `binding`，删除时写入空字符串，录制成功后同时更新 `name`、`command`、`binding`；
- 托盘菜单“退出”会先取消窗口拦截、销毁托盘，再强制结束 Dart/GTK 进程；仅调用 `windowManager.close()` 不足以结束隐藏的 GtkApplication 事件循环。
- 普通进程退出时才销毁托盘图标。

因此调 UI 时如果只运行普通命令，看不到窗口是正常的。要看框选 UI，可以按 `Alt+Z`，或运行：

```bash
fvm flutter run -d linux -- --capture
```

### 3.2 短生命周期捕获进程

`--capture` 进程不初始化托盘页面，而是进入 `CapturePage`：

1. GTK/Flutter 窗口创建但保持隐藏；
2. `CapturePage` 首帧后调用 `NativeBridge.captureScreen()`；
3. Rust 完成 ScreenCast + GStreamer 单帧 PNG；
4. Dart 解码 PNG；
5. 窗口才 `show()`、`focus()`；
6. `Esc`、保存成功或复制成功后关闭进程。

`linux/runner/my_application.cc` 中已经移除了旧的 `first-frame` 自动 `gtk_widget_show()`。这是故意的：如果 native first-frame 回调再次显示窗口，捕获时机就会被破坏。

### 3.3 托盘宿主取单实例锁

全局快捷键是**进程内**注册的（macOS 走 Carbon 的 `RegisterEventHotKey`），而系统只保证“同一个
bundle 路径”不会重复启动。用户从 DMG 里跑一份、`/Applications` 里再跑一份是很容易的事，
两份宿主各握一份快捷键，从其中一份的托盘菜单点“退出”，另一份照旧能截屏——表现就是
“退出之后按快捷键还能截图”。所以宿主进程启动时先抢独占权：

```text
lib/main.dart（非 --capture 分支）
SingleInstanceGuard.acquire()
    ↓ open + lockSync(FileLock.exclusive)   ← 内核级独占锁，非阻塞：拿不到就抛异常
    ├── 抛异常（已有宿主在跑）→ stderr 写一行，exitProcessNow()，不显示任何窗口
    └── 拿到 → 写入自己的 pid，句柄一直持有到进程退出
```

- **不要退回“记 PID + 查进程 + SIGTERM”的写法**：那样至少有三种翻车方式——两个宿主同时
  启动时的读-改-写竞态、PID 被复用后误杀别的进程（或误杀 `--capture` 进程）、以及旧宿主
  不退出时的“超时后照样接管”。文件锁由内核维护、进程一退出就释放，这些问题都不存在；
- 锁文件路径按平台选（macOS `~/Library/Application Support/<bundle id>/hax_shot.lock`，
  Linux 优先 `$XDG_RUNTIME_DIR`，Windows `%LOCALAPPDATA%`），实际路径无关紧要，只要
  两份宿主看到同一个文件；
- `--capture` 进程（`lib/main.dart` 的 `captureMode` 分支）**不参与**：它本来就该能同时开多个；
- `lib/app.dart` 的 `_quit()` 在 `finally` 里调 `SingleInstanceGuard.release()`（关句柄 +
  删文件）。放在最后一步：放太早会让下一份实例在快捷键还没注销完的时候启动；
- 拿不到/写不了锁文件时**不阻止启动**，只在 stderr 留一行（退化成允许多实例）：托盘工具
  起不来比多跑一份更糟。

### 3.4 托盘宿主的启动顺序

`lib/app.dart` 的 `_initializeDesktopIntegration()` 里的顺序是刻意排的，不要按“先注册
快捷键、再建图标”的直觉调换：

```text
lib/app.dart _initializeDesktopIntegration()
windowManager.setPreventClose(true)
    → windowManager.hide()
    → trayManager.setIcon(trayIconAsset)      ← 用户看到的第一样东西
    → trayManager.setContextMenu(...)
    → shortcutService.activate(onTriggered: _startCapture)
    → _presentFirstRunGuideIfNeeded()        ← 欢迎页
```

图标和菜单是用户唯一能操作托盘的入口，放最前面：`shortcutService.activate()` 要读
`SharedPreferences` 并走一次 Carbon `RegisterEventHotKey`，欢迎页要读磁盘
（`hax_shot.onboarding_seen`），这两步都会拖慢“菜单栏图标出现”。欢迎页放最后：它失败
也只影响自己，图标和菜单已经建好了。这里整体包在 `try/catch` 里，缺 AppIndicator 扩展
也不能阻断截图。

## 4. 无快门声截图管线

### 4.1 为什么不用 Screenshot Portal

`org.freedesktop.portal.Screenshot` 是标准授权接口，但 GNOME Wayland 的 Screenshot 路径可能播放截图闪光/相机声音。它适合普通“拍一张屏幕”的工具，不适合本项目的“先冻结、再框选”体验。

GNOME Shell 自己的截图 UI 使用 Mutter 内部的 `screenshot_stage_to_content()` 获取合成器内容，再在 Shell actor 上绘制遮罩。外部应用无法直接调用这个 Shell 内部对象，所以 Hax Shot 使用 Mutter 对外的 ScreenCast D-Bus 接口复现同样的顺序。

### 4.2 Rust 的实际调用顺序

`rust/src/lib.rs` 中的顺序不能随意调整：

```text
org.gnome.Mutter.DisplayConfig.GetCurrentState
    → 找到 primary monitor 的 connector

org.gnome.Mutter.ScreenCast.CreateSession
    → Session.RecordMonitor(connector, cursor-mode=0)
    → 监听 Stream.PipeWireStreamAdded
    → Session.Start
    → 得到 PipeWire node id

GStreamer:
pipewiresrc(path=node id, num-buffers=1)
    → videoconvert
    → pngenc
    → filesink(/tmp/hax-shot-*.png)

Session.Stop
    → 把 PNG 路径返回给 Dart
```

`cursor-mode=0` 表示不把鼠标光标放进冻结图，Flutter 只负责显示当前鼠标位置和选区边框。

### 4.3 为什么不能直接使用 `grim` 或 `scrot`

- `grim/slurp` 依赖 wlroots 的 `wlr-screencopy`，Mutter 通常不提供；
- `scrot` 是 X11 路径；
- GNOME Shell 的 Screenshot D-Bus 接口可能对普通应用返回 `AccessDenied`；
- 直接使用 Screenshot Portal 会重新触发本项目要避免的快门效果。

因此当前实现明确限定：**GNOME + Wayland + Mutter ScreenCast + GStreamer PipeWire**。

## 5. Rust/系统依赖

### Fedora 开发依赖

至少需要：

```bash
sudo dnf install -y \
  gstreamer1-devel \
  gstreamer1-plugins-base-devel \
  pipewire-devel \
  pipewire-gstreamer \
  gstreamer1-plugins-good \
  wl-clipboard \
  libayatana-appindicator-gtk3-devel
```

检查运行时插件：

```bash
gst-inspect-1.0 pipewiresrc
gst-inspect-1.0 pngenc
```

常见误区：Rust 的 `cargo build` 只会编译 Rust binding，不会把系统的 GStreamer/PipeWire 插件打包进 Flutter bundle。目标机器仍必须安装 `pipewiresrc`、`pngenc` 和 PipeWire 服务。

### `hotkey_manager_linux` 在 clang 22 上编译失败

`fvm flutter build linux --release` 编译插件时用的是本项目 `linux/CMakeLists.txt` 里的
`apply_standard_settings`，它带 `-Wall -Werror`。`hotkey_manager_linux 0.2.0` 的
`linux/hotkey_manager_linux_plugin.cc` 有两处局部指针可能未初始化（`handle_key_down` 的
`identifier`、`hkm_unregister` 的 `keystring`），clang 22 会直接把警告升级成错误：

```text
error: variable 'identifier' is used uninitialized whenever 'if' condition is false [-Werror,-Wsometimes-uninitialized]
error: variable 'keystring' is used uninitialized whenever 'if' condition is false [-Werror,-Wsometimes-uninitialized]
```

这是上游插件的真实 bug：`hotkey_id_map` 里查不到 key 时，未初始化的指针会被交给
`fl_value_new_string` / `keybinder_unbind`。文件不在本仓库，改的是 pub 缓存：

```text
~/.pub-cache/hosted/pub.dev/hotkey_manager_linux-0.2.0/linux/hotkey_manager_linux_plugin.cc
```

把两处 `if (result != hotkey_id_map.end())` 赋值改成“找不到就先退出”：

```cpp
  if (result == hotkey_id_map.end())
    return;                       // handle_key_down
  const char* identifier = result->first.c_str();

  if (result == hotkey_id_map.end())
    return FL_METHOD_RESPONSE(    // hkm_unregister
        fl_method_success_response_new(fl_value_new_bool(true)));
  const char* keystring = result->second.c_str();
```

patch 只存在于 pub 缓存，`flutter pub cache clean` / `pub cache repair`、切换 pub 镜像
或升级 `hotkey_manager` 之后都会丢失，届时按上面的方式重新打一遍。

### Rust 构建

```bash
cd rust
source "$HOME/.cargo/env"
cargo fmt --check
cargo check
cargo test
cargo build --release
```

Flutter 的 CMake 会自动执行：

```text
cargo build --manifest-path rust/Cargo.toml --release
```

即使 Flutter 是 debug 构建，Rust 库也放在 `rust/target/release/`，最终复制到：

```text
build/linux/x64/<mode>/bundle/lib/libhax_shot_native.so
```

### FFI 和临时文件

`hax_shot_capture_screen` 返回 NUL 结尾的临时 PNG 路径，而不是把整张图片通过 FFI 复制回 Dart。Dart 读取并解码后会尝试删除文件；删除失败时只保留临时文件，不影响截图结果。

`hax_shot_copy_png_to_clipboard` 通过：

```bash
wl-copy --type image/png
```

写入图片剪贴板。之前尝试 `wl-clipboard-rs` 时，GNOME compositor 不支持所需的 data-control 协议，因此不要在没有验证的情况下替换这条路径。

## 6. macOS 平台适配

macOS 与 Linux 共用同一套 Flutter UI 和 Dart FFI 接口，平台差异全部收敛在 Rust 和 Runner 里：

```text
Flutter（Linux / macOS 共用）
        │ Dart FFI：hax_shot_capture_screen / hax_shot_encode_png / hax_shot_png_buffer_size
        │           hax_shot_copy_png_to_clipboard / hax_shot_last_error
        ├── rust/src/linux.rs   Mutter ScreenCast + GStreamer + wl-copy + GNOME gsettings
        └── rust/src/macos.rs   CoreGraphics + ImageIO + NSPasteboard + Carbon
```

### 6.1 构建

macOS 需要 Xcode（含命令行工具）、CocoaPods 和 Rust 工具链：

```bash
fvm flutter pub get
fvm flutter run -d macos
fvm flutter build macos --release
```

`macos/Runner.xcodeproj` 的 “Build Rust Native Library” 脚本阶段会调用
`scripts/build_macos_rust.sh`：Debug 配置编译 cargo dev profile，Release/Profile 配置
编译 release profile，然后把 `libhax_shot_native.dylib` 复制到 `Contents/Frameworks`，
并用当前签名身份单独签名（Hardened Runtime 的 library validation 不接受未签名动态库）。

只构建 **Apple Silicon（arm64）**：不做 universal、不 lipo。`AppInfo.xcconfig` 里
`ARCHS = arm64`，脚本按 `$ARCHS` 的第一个架构构建对应 target，保证 dylib 和主程序同架构。
要支持 Intel 时删掉 `ARCHS` 那一行，并把脚本改成按 `$ARCHS` 逐架构构建后 `lipo -create`。

#### 本机安装：`scripts/install_macos_app.sh`

开发时不要把 `build/` 里的产物一个个手动拷过去，用脚本：

```bash
scripts/install_macos_app.sh                 # 构建 release + 装到 /Applications
scripts/install_macos_app.sh --dir ~/Apps    # 装到别的目录
scripts/install_macos_app.sh --zip out.zip   # 顺带打一个 zip
```

脚本依次做：`fvm flutter build macos --release` → `pkill -x hax_shot` 结束旧实例（托盘宿主
常驻，不退出会占住 bundle）→ 替换 bundle 并 `touch` → 用 LaunchServices 的
`lsregister -f` **显式登记**新 bundle（路径写死成
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`，
它是系统私有工具，不在 PATH 里）。

不登记的话，安装后第一次启动要现场做一遍 LaunchServices 注册，用户看到的就是“双击了图标，
菜单栏图标还要 3~5 秒才出来”；显式登记后第一次启动直接命中缓存。

### 6.2 屏幕录制权限

#### 开发时不要用 `flutter run` 去授权

macOS 把屏幕录制授权记在**责任进程**上。`flutter run` 启动的 app 是终端的子进程，
责任进程是终端：系统弹窗写的是“终端想要录制屏幕”，授权也记在终端名下，
**Hax Shot 自己不会出现在“屏幕录制”列表里**（macOS 15 的该面板还没有“+”可手动添加），
于是怎么都授权不了。

要调试权限相关功能，用 `open` 启动构建产物，让 Hax Shot 成为责任进程：

```bash
scripts/run_macos_debug.sh            # 构建 debug 并用 open 启动
scripts/run_macos_debug.sh --release
# 等价于：
open build/macos/Build/Products/Debug/hax_shot.app
```

`flutter run -d macos` 仍然适合调 UI —— 前提是你的**终端**已经有屏幕录制权限，
这时子进程会继承终端的授权（不会弹窗、列表里也没有 Hax Shot）。


macOS 不允许应用静默抓屏。关键是**没授权时绝对不能显示全屏浮层**：浮层是 borderless +
`.screenSaver` 层级、铺满整块屏，一旦在失败路径上弹出来，用户会被一块盖住菜单栏和 Dock
的黑屏困住（只剩 Esc 或强杀进程）。

所以窗口分两步走：

```text
--capture 进程启动
    ↓ 只是一个普通小窗口（560×480，带标题栏、层级 .normal）
Dart 先问 NativeBridge.screenCaptureAuthorized()（Rust: CGPreflightScreenCaptureAccess）
    ├── 未授权 → 显示 CapturePermissionGuide（小窗口里），并调用
    │             hax_shot_request_screen_capture_access()（CGRequestScreenCaptureAccess）
    │             弹一次系统对话框 + 把 Hax Shot 注册进“屏幕录制”列表
    │             用户点“打开系统设置”跳转，回来点“我已授权，重新检查”
    └── 已授权 → Rust 抓屏
            ├── 成功 → CaptureOverlayWindow.becomeOverlay()（borderless + .screenSaver +
            │          铺满目标显示器）→ 然后才 show()
            └── 失败 → 同样留在小窗口里显示错误（不再弹全屏浮层）
```

对应实现：

| 位置 | 职责 |
|---|---|
| `rust/src/macos.rs` | `screen_capture_authorized_impl` / `request_screen_capture_access_impl`；抓屏时权限缺失返回 ABI 错误码 **-3** |
| `lib/native/native_bridge.dart` | `screenCaptureAuthorized()` / `requestScreenCaptureAccess()`；-3 抛 `ScreenCapturePermissionException` |
| `lib/features/capture/capture_permission_guide.dart` | 引导页（步骤说明 + 打开系统设置 + 重新检查 + 退出） |
| `lib/features/capture/capture_overlay_window.dart` | 抓屏成功后调 `becomeOverlay` |
| `macos/Runner/CaptureOverlayWindow.swift` | 真正把窗口改成全屏浮层 |
| `lib/main.dart` | 捕获模式不再一启动就 `fullScreen`，也不再传 `alwaysOnTop` |

注意：`CGRequestScreenCaptureAccess()` 只在**显示引导页之前**调用一次，否则 app 不会
出现在“屏幕录制”列表里，用户无从勾选。`lib/main.dart` 捕获模式不传 `titleBarStyle`：
`window_manager` 的 macOS 实现会强解包标题栏按钮，在 borderless 窗口上直接 SIGTRAP
（引导窗口需要标题栏，浮层靠 Runner 自己切 borderless）。

重新构建会让 ad-hoc 签名指纹变化，TCC 记录可能失效，需要重新授权。

### 6.3 抓屏实现

```text
目标显示器 → CGDisplayCreateImage → ImageIO(CGImageDestinationCreateWithURL) → 临时 PNG
```

`CGDisplayCreateImage` 返回物理像素，Retina 屏上是逻辑尺寸的 2 倍；Flutter 侧按逻辑点
铺满同一块显示器，正好 1:1 显示，裁剪和标注仍然按物理像素计算。目标显示器怎么定
见 [6.9 多显示器](#69-多显示器)。

### 6.4 抓屏浮层

macOS 不使用 `windowManager.setFullScreen()`：原生全屏会切到独立 Space 并播放动画，
而 `alwaysOnTop` 只到 `.floating` 层级，盖不住菜单栏和 Dock。改为在
`macos/Runner/MainFlutterWindow.swift` 里判断 `--capture` 参数，直接设置：

```text
styleMask          = [.borderless]
level              = .screenSaver
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
frame              = CaptureDisplay.targetScreen().frame
```

浮层只铺满**目标显示器**（不是全部显示器的并集），因此冻结画面和窗口尺寸一一对应。
实测 borderless 窗口用 `setFrame(screen.frame)` 不会被 AppKit 收缩到 `visibleFrame`，
菜单栏和 Dock 区域也在窗口内。

窗口仍然保持隐藏，由 Dart 在拿到冻结帧后调用 `show()`，保持“先截图、后显示”的顺序。
`lib/main.dart` 因此只在非 macOS 平台传 `alwaysOnTop/fullScreen`。

### 6.5 剪贴板

`NSPasteboard` 只能在主线程访问，因此 `NativeBridge.copyPngToClipboard()` 在 macOS 上
不再包 `Isolate.run`，直接在主 isolate 调用；Linux 仍然保留 worker isolate。

### 6.6 全局快捷键

macOS 没有 gsettings，用成熟的第三方包 **`hotkey_manager`**（macOS 端依赖 soffes/HotKey，
底层是 Carbon `RegisterEventHotKey`）注册全局热键，不自己写 Carbon 调用。

首次启动时如果没有已保存的绑定，会写入并使用默认值 `<Alt>z`（即 `⌥Z`）——菜单栏图标
可能被 Bartender 之类的工具收进隐藏区，所以必须有一个不依赖图标的入口。

```text
托盘宿主启动
    ↓ shortcutService.activate(onTriggered: _startCapture)
macOS: hotkey_manager 注册（见 lib/features/settings/macos_shortcut_service.dart）
Linux: 不动，GNOME gsettings 自己启动 `hax_shot --capture`
    ↓ 热键按下
onTriggered → 和点托盘菜单“立即截屏”同一条路径（读光标所在屏 → 起 --capture 子进程）
```

绑定字符串与 Linux 共用同一种格式，由 `lib/features/settings/hotkey_binding.dart` 解析：

```text
<Super><Shift>z   →  macOS ⌘⇧Z
<Alt>z            →  Linux Alt+Z
```

`hax_shot_register_capture_hotkey` 必须从 Dart 主 isolate 调用，Carbon 事件处理器要装在
主线程 RunLoop 上；`--capture` 进程不注册热键。

### 6.7 开机自启动

`MacosAutostartService` 写入 `~/Library/LaunchAgents/com.github.xiehanff.haxShot.plist`
（`RunAtLoad`）。只写文件，不调用 `launchctl bootstrap`：LaunchAgent 会在下次登录时由
launchd 自动加载，而立即 bootstrap 会在用户已经运行托盘宿主时再开一个实例。

### 6.8 macOS 特有文件

| 文件 | 职责 |
|---|---|
| `macos/Runner/MainFlutterWindow.swift` | `--capture` 浮层的窗口层级和 frame |
| `macos/Runner/CaptureDisplay.swift` | 目标显示器选择，规则必须和 Rust 保持一致 |
| `macos/Runner/AppDelegate.swift` | 关闭设置窗口不结束进程 |
| `macos/Runner/Info.plist` | `LSUIElement`（菜单栏应用，无 Dock 图标）、显示名 |
| `macos/Runner/*.entitlements` | 关闭 App Sandbox，允许加载 cargo 产出的动态库 |
| `macos/Runner/Configs/Warnings.xcconfig` | `ENABLE_USER_SCRIPT_SANDBOXING = NO` |
| `scripts/build_macos_rust.sh` | cargo 构建并复制 dylib 到 bundle |
| `lib/features/settings/macos_shortcut_service.dart` | 快捷键持久化和原生注册 |

### 6.9 多显示器

macOS 已支持多显示器：**截图目标和浮层始终是同一块显示器**，按下面的顺序决定：

```text
1. --display <id>   托盘宿主在按下快捷键/菜单的那一刻取得并传给子进程
2. 光标所在显示器     没有传 --display 时的兼容路径
3. 主显示器          前两者都拿不到时的兜底
```

这个顺序在两处各实现一次，必须保持一致：

```text
rust/src/macos.rs                  target_display()
macos/Runner/CaptureDisplay.swift  CaptureDisplay.targetScreen()
```

为什么不让两边各自去查光标：`--capture` 子进程从启动到 Dart 真正开始抓屏有几百毫秒，
如果这期间用户把鼠标移到另一块屏，两边就会得出不同结果，出现“浮层在 A 屏、画面是
B 屏”。所以托盘宿主只在**触发的那一瞬间**读一次光标，把显示器标识当作命令行参数
固定下来：

```text
macOS：按快捷键（hotkey_manager 回调）／点托盘菜单 —— 都在宿主进程里读
Linux：GNOME 自定义快捷键直接启动 hax_shot --capture，拿不到光标屏（见上面的硬约束）
    ↓ NativeBridge.cursorDisplay() → hax_shot_cursor_display()
    ↓ hax_shot --capture --display <id>
    ├── Rust：hax_shot_capture_screen 按 <id> 抓屏
    └── Swift：CaptureDisplay.targetScreen() 把浮层铺到同一块屏
```

DPI：抓屏是物理像素，浮层是该显示器的逻辑尺寸，`ScreenshotLayout.fromViewport` 会自动
算出 `scale`（Retina 2x 屏上是 0.5），裁剪、标注、导出仍然按物理像素计算。混合 DPI
（内置 2x + 外接 1x）不需要特殊处理，每次截图只涉及一块屏。

**不做的**：不支持一次框选跨越两块屏。macOS 开了「显示器有独立 Space」（默认）时
WindowServer 会把窗口限制在一块屏上，跨屏选区必须为每块屏各开一个浮层窗口（Capso、
Snapzy、better-shot、flameshot 都是这个架构），属于独立的一步；详见
[`docs/reference-decisions.md`](./reference-decisions.md)。

#### 调试授权引导的入口

托盘菜单在 debug 构建里多一项 **“权限引导（调试）”**（`lib/app.dart` 里用 `kDebugMode`
控制）：点它会按 560×480 打开 `CapturePermissionGuide`，用于反复调这个页面的 UI，
不影响真实权限状态。“我已授权，重新检查”在调试模式下只反馈当前真实授权状态。

#### macOS 窗口交给 Flutter 自己管

不要 macOS 原生的红黄绿按钮（它们会压在 Flutter AppBar 自己的 ✕ 上）：

- 托盘宿主/设置窗口：`WindowOptions.windowButtonVisibility = false`（`window_manager`
  的 macOS 实现里是 `standardWindowButton(...)?.isHidden = true`）；
- `--capture` 进程的窗口（引导/错误态）：Runner 直接 `styleMask = [.borderless]`，
  抓屏成功后由 `CaptureOverlayWindow.becomeOverlay()` 改成全屏浮层。
  无边框窗口靠 Flutter 自己拖：引导页标题行绑定了 `windowManager.startDragging()`。

#### 窗口圆角

**macOS 只对 titled 窗口做原生圆角裁剪**：borderless 窗口不会被裁，四角外侧露出的是
窗口自己的背景色，看起来就是“有圆角但不透”。所以捕获进程的窗口（授权引导、AI 面板
都在这里面）和托盘宿主的窗口一样，用
`CaptureOverlayWindow.applyPanelAppearance(to:)` 配成
`.titled + .fullSizeContentView` + 透明隐藏标题栏：既拿到系统原生圆角（角外直接是
桌面），又保持无标题栏观感，还不会出现 macOS 的红黄绿（没有 `.closable` 等，三个按钮
是 nil）。`RunnerTests.testPanelAppearanceUsesNativeRoundedWindow` 守着这个配置。

抓屏成功后 `becomeOverlay()` 会把它切成 `[.borderless]`：全屏浮层必须铺满屏幕、盖住
菜单栏和 Dock，不能有圆角。`exitOverlay()` 再切回面板外观。

Windows/Linux 的窗口本身没有圆角，靠 `RoundedWindow`（`ClipRRect`，半径 12）裁一刀 +
窗口背景透明做出圆角；这两个平台上它才生效（见 `rounded_window.dart`）。**截图浮层
（`CapturePage`）永远不要包 `RoundedWindow`**：那里必须直角铺满。

#### Linux 的窗口透明是怎么来的

Linux 只裁 `ClipRRect` 是不够的：窗口自己有背景色，裁掉的那四个角会露出方形底色
（用户报的就是“背景方形 + Flutter UI 有圆角”）。要真正透明，下面几处缺一不可：

1. `linux/runner/my_application.cc` 把窗口的 visual 换成 RGBA，并 `app_paintable`，
   否则合成到桌面的帧没有 alpha 通道；
2. 同一个文件里给窗口加 `hax-shot-rounded` CSS 类，把 `window` / `decoration` 的
   `background-color`、`background-image`、`border`、`box-shadow` 全部清掉：Adwaita
   会在这些节点上画底色和 CSD 阴影，不清就还是一圈方形边框；
3. `fl_view_set_background_color(view, "#00000000")`。引擎里 `paint_background` 在
   alpha 为 0 时直接跳过绘制（见 `shell/platform/linux/fl_view.cc`），所以这一步是让
   引擎不再在图没铺到的地方画黑底；
4. `lib/main.dart` 的 `WindowOptions.backgroundColor` 在 Linux 传 `Colors.transparent`：
   window_manager 的 Linux 实现会把它写成全局 CSS `window { background-color: ... }`，
   传黑色就等于又给窗口涂了一层黑底。

拿不到 RGBA visual（例如 X11 没开合成器）时 runner 会退回不透明黑底：那种环境下
透明窗口露出的是未初始化的画面。所以“圆角处是黑的”先确认会话是 Wayland/GNOME，
再看上面四处是否都在。

macOS 不受影响：它靠系统 titled 窗口画原生圆角，`RoundedWindow` 在那边不生效。

#### 保存/复制：PNG 编码走 Rust，浮层先收起

release 实测（1920x1080 真实截图，`--bench-export` 对比两条路径，解码后逐字节比对）：

```text
Skia  Image.toByteData(png)                        534ms   2037KB  ← 用户感觉“很慢”的原因
Rust  toByteData(rawStraightRgba) + hax_shot_encode_png
                                             6.6ms + 15ms  2389KB
```

所以 `ScreenshotExporter.renderPng` 取 `rawStraightRgba` 后交给
`NativeBridge.encodePng`（worker isolate 里调 `hax_shot_encode_png`）。Rust 用
`png` crate 的 `Compression::Fast`（底层 fdeflate，专为 PNG 调过），代价是体积约
+17%。同一张图在 Rust 侧的其它档位实测：`Balanced` 452ms、`High` 1753ms——别为了省
那点体积换回去。

FFI 约定：`hax_shot_png_buffer_size(width, height)` 给输出缓冲区容量上界（含每行
filter 字节和 deflate 膨胀余量），`hax_shot_encode_png` 返回写入字节数，缓冲区不足
返回 **-2**、其它失败返回 **-1**。缓冲区必须够大，否则编码是白做的。

动作顺序是：**拿到路径/开始复制后先 `windowManager.hide()`，再编码、写盘或写剪贴板，
最后调 `exitProcessNow()`**。用户点完“保存/复制”浮层立刻消失，不用盯着冻结画面等编码；
人切换到目标应用再按 ⌘V 至少几百毫秒，编码早就完成了。出错时用 `_restoreOverlay()` 把
浮层放回来，否则用户既没拿到图也看不到错误。

**结束进程必须用 `lib/features/app/hard_exit.dart` 的 `exitProcessNow()`**（`SIGKILL`
自己），不要用 `dart:io` 的 `exit(0)`：在 macOS 上 `exit(0)` 会挂在 Flutter 引擎注册的
atexit 收尾里，进程继续活着——窗口和托盘图标都消失了，`pgrep -x hax_shot` 还能看到。
捕获进程每次截图后走的就是这条路，泄漏的进程会越攒越多；托盘“退出”之后快捷键还生效
也是同一个原因（Carbon 注册随进程存活）。`await windowManager.destroy()` 也不能替代：
`main()` 早期插件通道还没注册，这个 Future 永远不返回。Swift 侧同理用 `_exit(0)`
（见 `CaptureOverlayWindow.swift` 的 Esc 监听）。

#### 启动时不能闪一个黑窗口（macOS）

nib 会在启动阶段就把主窗口排到最前，而这时 Flutter 还没画出第一帧，用户会看到一个小黑
窗口闪一下（托盘宿主和捕获进程都这样，实测 800x600 出现在 0.17–0.22s）。

做法：`MainFlutterWindow.awakeFromNib` 里 `alphaValue = 0`，窗口可见性完全交给 Dart ——
显示统一走 `lib/features/window/window_visibility.dart` 的 `showWindow()`（先
`setOpacity(1)` 再 `show()`）；浮层由 `CaptureOverlayWindow.becomeOverlay()` 恢复。

> 不要改成在 `MainMenu.xib` 上加 `visibleAtLaunch="NO"`：实测这样 Flutter 引擎根本不
> 启动（窗口不创建、`awakeFromNib` 不执行），app 变成没有任何窗口的空壳。

#### 浮层必须永远能退出（血泪教训）

捕获进程是 `.screenSaver` 层级、铺满整块屏的浮层：**一旦它退不出去，用户连菜单栏都点不到，
整台电脑就没法用了**。所以：

- Esc 有**原生兜底**：`CaptureOverlayWindow.installEscapeMonitor()` 装 local monitor，
  窗口覆盖整屏时直接 `_exit(0)`。不依赖 Flutter 焦点树，也不依赖 `performClose`
  （后者对无边框窗口不一定生效）。
- 引导页、AI 面板各有自己的 Esc 处理；AI 面板还有右上角 ✕。
- **AI 面板接管同一个窗口前，必须先把浮层状态退掉**：`CaptureOverlayWindow.exitOverlay()`
  恢复 `level = .normal` 和 `collectionBehavior = []`，再让 Dart 改尺寸。顺序反了的话，
  一旦改尺寸失败，窗口就停在“全屏 + .screenSaver”，用户被锁死。
- 不要再引入“忽略下一次关闭”这类隐式标志：CapturePage 的 AI 路径以前靠
  `_ignoreNextWindowClose` 阻止进程退出，标志没被消费时窗口就永远停在截图态、Esc 也失效。
  现在 AI 路径**不调用** `_closeCapture()`，由 AI 面板接管窗口，取消/保存/复制则正常退出。

#### 两个实际运行才暴露的坑

1. **捕获模式不能传 `titleBarStyle`**：`window_manager` 的 macOS 实现里
   `setTitleBarStyle` 会执行 `(mainWindow.standardWindowButton(.closeButton)?.superview)!.superview!`，
   borderless 窗口没有标题栏按钮，直接强解包 nil 触发 SIGTRAP；它还会把窗口改成半透明
   带阴影，和冻结画面浮层冲突。所以 `lib/main.dart` 只在非捕获模式传 `titleBarStyle`。
2. **捕获模式不能传 `alwaysOnTop` / `fullScreen`**：`setAlwaysOnTop(false)` 会把窗口层级
   写成 `.normal`、`true` 写成 `.floating`，都会覆盖 Runner 设好的 `.screenSaver`，
   结果是浮层盖不住菜单栏和 Dock。这两个选项在 macOS 捕获模式下传 `null`。
   验证方法：`CGWindowListCopyWindowInfo` 里浮层应该是 `layer=1000`。

#### Linux

Linux（GNOME Wayland）目前仍然只抓主显示器，是协议层硬约束：

- Wayland 不向客户端提供全局指针位置（`wl_pointer` 只在指针进入自己的 surface 时有事件），
  拿不到“用户在哪块屏”；`hax_shot_cursor_display` 在 Linux 上直接返回 0；
- Wayland 客户端不能自己摆放窗口（`xdg-shell` 没有 set_position），
  `windowManager.setFullScreen()` 后是哪块屏由 Mutter 决定，无法和抓屏目标对齐。

要支持得在 GTK runner 里为每块屏各开一个窗口，属于独立的一步。

## 7. 选区坐标规则

Flutter 侧使用：

```text
原点：左上角
方向：x 向右，y 向下
单位：logical pixel
```

PNG 使用：

```text
原点：左上角
方向：x 向右，y 向下
单位：physical pixel
```

`ScreenshotLayout` 负责：

1. 将完整 PNG 按比例 fit 到 Flutter viewport；
2. 将鼠标位置 clamp 到 `imageRect`；
3. 将选区从 logical 坐标转换成 PNG pixel rect；
4. 使用 floor/ceil 保证边界覆盖；
5. 在 `Canvas.drawImageRect` 中生成最终 PNG。

不要在 Dart 和 Rust 两边重复缩放或翻转 Y 轴。新增标注、裁剪或导出功能时，必须复用 `ScreenshotLayout.toPixelRect()` 的规则。

当前 MVP 只保证主显示器/单显示器场景。`DisplayConfig` 只选择 primary connector，不能把多显示器偏移直接当成单屏坐标使用。

## 8. 快捷键设置、录制与 desktop 文件

### 默认快捷键

安装脚本设置：

```text
gsettings binding = <Alt>z
```

快捷键不是 Flutter 内部注册的。Wayland 下普通应用不能可靠地伪造任意全局热键，所以由 GNOME 自定义快捷键执行：

```text
hax_shot --capture
```

### `Exec` 和 desktop ID 的区别

脚本会写入：

```text
~/.local/share/applications/com.github.xiehanff.hax_shot.desktop
```

这个文件使用：

```text
Exec=/.../hax_shot
Icon=com.github.xiehanff.hax_shot
NoDisplay=false
StartupWMClass=com.github.xiehanff.hax_shot
```

注意：`Exec` 是普通 tray 宿主，不是 `--capture`；真正的快捷键命令由 gsettings 单独保存为 `hax_shot --capture`。`NoDisplay=false` 让 Hax Shot 出现在 GNOME 应用列表中；从应用列表启动后仍只驻留托盘，不显示主窗口。

桌面文件名、Wayland app ID、`StartupWMClass`、图标名必须保持一致：

```text
com.github.xiehanff.hax_shot
com.github.xiehanff.hax_shot.desktop
com.github.xiehanff.hax_shot.png
```

以前 Dock 显示 Flutter 默认图标，核心风险就是这些标识不一致、旧 desktop 文件残留或图标缓存没有刷新。

### 设置页的快捷键录制规则

实现文件：`lib/features/settings/shortcut_settings_page.dart`。

设置页只依赖 `ShortcutService` 接口：Linux 实现在 `gnome_shortcut_service.dart`（gsettings），
macOS 实现在 `macos_shortcut_service.dart`（shared_preferences + 原生全局热键）。
录制产出的绑定字符串两个平台共用，macOS 侧由 `rust/src/macos.rs` 解析。

当前规则参考 Cliper 的以下实现：

```text
/home/han/Documents/github/cliper/lib/presentation/widgets/header/header_widget.dart
/home/han/Documents/github/cliper/lib/application/controllers/settings_handler.dart
```

当前规则与 Cliper 的录制逻辑保持一致：

- 只处理 `KeyDownEvent`；
- 单独按下 Ctrl/Alt/Shift/Super 不提交；
- 必须包含至少一个修饰键和一个主体按键；
- `Esc` 取消录制；
- 组合键转成 GNOME 格式，例如 `Alt+Z` → `<Alt>z`、`Ctrl+Shift+4` → `<Control><Shift>4`；
- 新快捷键保存到固定 schema，并确保 `custom-keybindings` 数组包含 `hax-shot` 路径；
- 删除只清空 `binding`，保留 relocatable schema，方便下一次录制直接恢复；
- 设置页关闭/隐藏后不销毁托盘宿主。

这里有一个容易踩的坑：`gsettings get` 返回的是带引号的 GVariant 文本，例如 `'<Alt>z'`，不能直接把整行当作显示文本；代码需要先去除 GVariant 引号，再转换为 `Alt+Z`。

### 开发模式的额外行为

debug 构建中 `my_application.cc` 会把 bundle 内的图标复制到：

```text
~/.local/share/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png
```

并动态生成一个带绝对路径的开发 desktop 文件，方便 `fvm flutter run` 的窗口被 GNOME 识别。这个文件可能把 release desktop 的 `Exec` 临时改成 debug 路径。

所以在验证 GNOME 快捷键前，建议重新执行：

```bash
./scripts/install-gnome-shortcut.sh
```

如果项目目录移动过、build 目录清理过或 release 路径变化，也必须重新执行脚本。

## 9. 截图选区后的工具栏定位

实现文件：

```text
lib/features/capture/selection_toolbar_placement.dart
lib/features/capture/capture_page.dart
```

参考实现：

```text
/home/han/Documents/github/plume-pdf/lib/app/modules/home/views/widgets/pdf_page_area_selection_overlay.dart
/home/han/Documents/github/plume-pdf/lib/app/modules/home/views/widgets/selection_toolbar_placement.dart
```

工具栏不再固定在屏幕底部，而是参照 Plume PDF AI 框选工具栏的策略。**拖拽进行中不显示工具栏，只有 `onPanEnd` 确认有效选区后才显示**，这样定位算法拿到的是最终矩形，而不是不断变化的中间矩形。

1. 选区下方有足够空间时，放在选区下方；
2. 下方放不下、上方放得下时，放在选区上方；
3. 上下两侧都不足可用空间时，把工具栏放在选区中心；
4. 工具栏水平方向始终跟随选区中心，并在左右边缘做 clamp；因此左侧框选不会跑到屏幕中心，右侧框选也不会被截断；
5. 通过 `CustomSingleChildLayout` 获取真实工具栏尺寸，不能写死宽度，因为字体、按钮文字和主题可能改变组件宽度；同时必须在 `SingleChildLayoutDelegate.getConstraintsForChild` 中返回 `constraints.loosen()`，否则子工具栏会被施加全屏紧约束，既会跑到左上/左侧，也会让其背景遮住整张截图；
6. viewport 和 toolbar 都留 12px 边距，避免贴住屏幕边缘。

当前 `CaptureToolbar` 包含取消、保存、复制、截图框选、矩形标注、箭头标注、文字标注、颜色板（红/紫/黄/绿/橙）以及截图 AI 操作：翻译、解释、深入理解。图标统一使用 `hugeicons` 的 `strokeRounded` 风格；矩形和箭头通过拖拽绘制，文字工具通过单击创建输入框，并可拖动四角缩放字号。颜色由 CapturePage 持有并用于预览和最终 PNG。拖拽中的临时矩形仍然绘制边框，但工具栏要等 `selectionCommitted` 在 `onPanEnd` 中变为 true 后才显示。开始下一次截图选区拖拽时立即清空旧标注。

已添加 `test/selection_toolbar_placement_test.dart` 覆盖顶部、底部、左右边缘、几乎占满屏幕，以及真实 `CustomSingleChildLayout` 尺寸约束。

## 10. 截图 AI 与对话侧栏

截图工具栏的三个 AI 操作都会先调用 `ScreenshotExporter.renderPng()`，把当前选区和矩形、箭头、文字标注合成为最终 PNG，再发送给 AI：

```text
截图选区 + 标注
      ↓
ScreenshotExporter
      ↓
AiImageAttachment(image/png)
      ↓
HaxAiController
      ↓
plume_ai_chat / DeepSeek SSE
```

AI Host 代码位于：

```text
lib/features/ai/
├── controllers/hax_ai_controller.dart
├── models/
├── services/
└── views/
```

通用对话能力完整复用 `packages/plume_ai_chat`，包括 reasoning、流式 Markdown、Stop、会话历史、图片输入和 follow-up suggestions。普通追问只发送文字，不会重复上传上一张截图；新的截图操作会新建视觉会话。

AI 窗口是截图子进程中的普通页面，不新增第二个原生窗口。标题栏支持拖动，右上角关闭按钮结束当前截图进程。API Key 保存到 `shared_preferences`，key 为 `hax_shot.deepseek_api_key`。

### AI 面板顶部条

`lib/features/ai/views/widgets/ai_sidebar.dart` 的 `_AiTitleBar` 只负责把顶部条和消息区
区分开，**不放标题文字**（原来那个 “AI” 文本已经去掉）：

```text
高度       66 → 44
底色       AppColors.titleBarBg = #0C0D11（比正文 scaffoldBg = #121318 更暗）
关闭按钮   top: 10 / right: 16（原来是 top: 19 / right: 20）
```

整条仍然是 `DragToMoveArea`（窗口没有原生标题栏）；macOS 的窗口圆角由系统的 titled 窗口
画，顶部条铺满即可，见 [窗口圆角](#窗口圆角)。`test/ai_panel_chrome_test.dart` 守着顶部条
存在、且 `titleBarBg` 与 `scaffoldBg` 不同。

## 11. 图标更换流程

当前图标由 `skills/icns-handle` 从外部 `.icns` 提取并生成 Linux PNG 组，源文件不进入仓库。

使用脚本生成 Linux hicolor 图标组：

```bash
python3 /path/to/icns_handle.py generate source.icns \
  -o /tmp/hax_shot_icons -p linux -n hax_shot
```

当前工程有两份用途不同的图标：

| 路径 | 用途 |
|---|---|
| `assets/icons/hax_shot.png` | Flutter `tray_manager` 和 Flutter 资源 |
| `linux/icons/hicolor/*/apps/com.github.xiehanff.hax_shot.png` | GNOME desktop/icon theme |
| `linux/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png` | GTK runner 的 `data/hax_shot_icon.png` 来源 |
| `linux/icons/hax_shot.png` | 256px 兼容副本，不是 hicolor 主来源 |

更换图标后必须同时完成：

```bash
fvm flutter build linux --release
./scripts/install-gnome-shortcut.sh
```

正在运行的托盘进程通常已经缓存了旧图标，必须退出并重新启动 Hax Shot；只替换 PNG 文件不一定会立即刷新已经显示的 AppIndicator 图标。

### 品牌色（`lib/hax_colors.dart`）

`haxAccent = #F8C800` 取自图标主色（`assets/icons/hax_shot_source.png`），配一个压暗的
`_onHaxAccent = #1F1800`：深色背景上用亮姜黄，按钮里的文字/图标必须压暗才看得清。
`haxAccentTheme(base)` 只覆盖 `colorScheme` 的 `primary/onPrimary/secondary/onSecondary` ——
`FilledButton` / `OutlinedButton` / `TextButton` 的前景和背景都取 `colorScheme.primary`，
覆盖它就够了。

只用在这两个“要用户动手”的页面上，其余页面保持默认深色主题：

```text
lib/features/capture/capture_permission_guide.dart   Theme(data: haxAccentTheme(theme))
lib/features/settings/shortcut_settings_page.dart    Theme(data: haxAccentTheme(Theme.of(context)))
```

## 12. 调试和验证清单

### Dart/Flutter

```bash
fvm flutter analyze
fvm flutter test
fvm flutter build linux --debug
fvm flutter build linux --release
```

### Rust

```bash
cd rust
source "$HOME/.cargo/env"
cargo fmt --check
cargo check
cargo test
```

### desktop/icon

```bash
desktop-file-validate \
  packaging/hax_shot.desktop \
  build/linux/x64/release/bundle/share/applications/com.github.xiehanff.hax_shot.desktop \
  "$HOME/.local/share/applications/com.github.xiehanff.hax_shot.desktop"

sha256sum \
  assets/icons/hax_shot.png \
  linux/icons/hicolor/256x256/apps/com.github.xiehanff.hax_shot.png \
  build/linux/x64/release/bundle/data/hax_shot_icon.png
```

### 运行时检查

普通进程应该没有 Wayland toplevel，只保留托盘图标：

```bash
WAYLAND_DEBUG=1 build/linux/x64/debug/bundle/hax_shot
```

捕获进程应该在 Rust 返回 PNG 后才出现全屏 toplevel：

```bash
build/linux/x64/debug/bundle/hax_shot --capture
```

不要用宽泛的 `pkill -f 'fvm flutter run -d linux'` 清理进程，它可能误杀其他项目的 Flutter 调试会话。优先根据工作目录和 PID 判断，或者只使用：

```bash
pkill -x hax_shot
```

## 13. CI 与 GitHub Release

GitHub Actions 配置位于 `.github/workflows/build-rpm.yml`，只在推送 `v*` tag 时运行。普通 `main` push、Pull Request 和手动运行不会触发发布。

发布前本地执行：

```bash
fvm flutter analyze
fvm flutter test
fvm flutter build linux --release
cargo fmt --manifest-path rust/Cargo.toml --check
cargo check --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml
```

tag 去掉 `v` 后必须匹配 `pubspec.yaml` 中 `+` 前的版本号：

```text
version: 1.3.0+1  →  git push origin v1.3.0
```

推送 tag 后，工作流会重新执行 Dart/Rust 检查，构建 Fedora x86_64 RPM，保存 Actions artifact，并把 RPM 上传到对应 GitHub Release。不要为普通开发 commit 创建 `v*` tag；完整操作见 [`ci-release.md`](./ci-release.md)。

## 14. 已知限制和未完成项

Linux：

- 仅支持 GNOME + Wayland；
- 仅支持主显示器，多显示器需要改成“每块屏一个浮层窗口”，见 [6.9 多显示器](#69-多显示器)；
- 不支持 X11、KDE、wlroots compositor；
- ScreenCast 服务或 GStreamer 插件不可用时会失败，不使用有快门声的 Portal 兜底；
- AppIndicator 依赖 GNOME Shell AppIndicator 扩展，Fedora 可能打印 deprecated warning，但当前功能正常；
- system GStreamer/PipeWire 依赖不会随 Rust `.so` 一起分发；
- 关闭或杀掉 tray 宿主后，GNOME 自定义快捷键仍可能指向旧的 release 路径，需要重新安装快捷键。

macOS：

- 首次截图必须在系统设置里授予“屏幕录制”权限；
- bundle 目前是 ad-hoc 签名，重新构建后 TCC 授权可能失效，需要重新授权；
- 菜单栏直接复用 Linux 的彩色图标（`assets/icons/hax_shot.png`，18pt）。深色菜单栏上对比度偏低，后续需要一张单色 template 图标；
- 还没有 DMG 打包、公证（notarization）和 `AppIcon`（仍是 Flutter 默认图标）；
- 还没有 macOS 的 CI 构建任务，本地验证使用 `fvm flutter build macos`；
- 不支持跨显示器框选：一次截图只覆盖目标显示器，选区不能跨越两块屏。

两个平台共同：

- 暂不捕获鼠标光标；
- 暂不支持 OCR、贴图、持久化会话、录屏和滚动截图；AI 会话仅在当前进程内保留；
- 快捷键每次启动独立 `--capture` 进程，尚未实现多次触发的单实例锁；
- 托盘宿主有单实例保护（`lib/features/app/single_instance_guard.dart`）：`lib/main.dart`
  的非 `--capture` 分支调 `acquire()`，用的是内核级文件锁（`FileLock.exclusive`，非阻塞），
  拿不到就直接 `exitProcessNow()`；`lib/app.dart` 的 `_quit()` 在最后调 `release()`。**没有它会出现
  “从托盘退出后按快捷键还能截图”**——两份宿主各自注册了进程内的全局快捷键，退出的只是
  其中一份。不要改成“记 PID + SIGTERM”：有竞态和 PID 复用误杀的风险。Linux 上同类问题是
  gsettings 里的快捷键指向旧的 release 路径，要重跑 `scripts/install-gnome-shortcut.sh`；
- 还没有默认快捷键：Linux 需要运行 `scripts/install-gnome-shortcut.sh`，macOS 需要在设置页录制。

## 15. 给后续 Agent 的最短交接信息

如果任务是调整捕获 UI：只改 `lib/features/capture/`，保持 `_capture()` 完成后再 `windowManager.show()`。

如果任务是调整托盘：只改 `TrayHostPage`，不要添加主应用窗口；截图必须通过 `--capture` 子进程启动。

如果任务是调整截图后端：先阅读 `docs/snapclip-source-review.md`，保持 Mutter ScreenCast 的调用顺序，不要替换为 Screenshot Portal。

如果任务是多显示器：先读 [6.9 多显示器](#69-多显示器)。macOS 改动 `rust/src/macos.rs` 的
`target_display()` 时必须同步改 `macos/Runner/CaptureDisplay.swift`；两边一旦不一致就会出现
浮层和画面不在同一块屏的 bug。Linux 需要多窗口架构，不能只改抓屏。
要支持跨屏框选，必须改成“每块屏一个浮层窗口 + 跨窗口选区同步”，不要试图用一个窗口去跨屏。

如果任务是调整图标/Dock 匹配：先检查 application ID、desktop 文件名、`Icon` 名称和 `StartupWMClass`，再用 `icns-handle` 生成图标、运行安装脚本并重启旧进程；Wayland 下 GNOME Dock 仍使用旧缓存时需要注销并重新登录。

如果任务是增加跨平台支持：先明确不能把当前 Mutter/GStreamer 路径抽象成所有 Linux 桌面的通用方案；应新增后端并保留 GNOME backend，参考 `rust/src/macos.rs` 的做法：平台实现只暴露 `capture_screen_impl` / `copy_png_impl` / `register_capture_hotkey_impl` 三个函数。

一句话记忆：**先确定这是 tray 宿主还是 `--capture` 窗口，再修改对应层；不要让隐藏时序、desktop ID 或 ScreenCast 顺序被无意破坏。**
