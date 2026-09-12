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
| `lib/hax_colors.dart` | 主题色 `#8FAEC9`（灰蓝）和 `haxAccentTheme()` | 应用内不用姜黄；`haxAccentTheme()` 只包在设置页外层（欢迎页/授权引导改用 `panel_chrome.dart` 的按钮样式）；改色值要同步 `lib/app.dart` 的 `seedColor` |
| `lib/features/window/panel_chrome.dart` | 欢迎页 / 授权引导共用的面板视觉（`PanelColors` / `PanelText` / `PanelButtons` / `PanelHeader` / `PanelCard` / `PanelNote`） | 新加这类“临时小窗口”直接用它，别在页面里另写一套字号和圆角；`PanelHeader` 整条可拖，标题必须套 `IgnorePointer` |
| `lib/features/settings/shortcut_settings_page.dart` | 快捷键录制、开机自启动开关 | 快捷键通过 `gsettings` 写入，启动项通过 `AutostartService` 写入当前用户 XDG 配置 |
| `lib/features/capture/capture_page.dart` | 冻结图加载、框选、保存、复制 | `_capture()` 完成前不要显示捕获窗口；保存/复制使用同一份裁剪逻辑 |
| `lib/features/capture/capture_toolbar.dart` | 磨砂玻璃工具条、HugeIcons 图标和标注工具 | 保持全圆角、纯白图标、BackdropFilter；外圈 2px 玻璃边是灰蓝渐变 `haxAccent` → `haxAccentDeep`（原来是紫→靛，别改回去）；矩形/箭头/文字工具通过 callback 切换，颜色由 CapturePage 持有并用于预览和最终 PNG |
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
5. 窗口才 `show()`、`focus()`；macOS 先在 `becomeOverlay()` 里激活 LSUIElement 应用，
   避免 AppKit 把快捷键启动的浮层排到当前前台窗口后面；
6. `Esc`、保存成功或复制成功后关闭进程。

隐藏阶段的原生抓屏最多等 5 秒；否则用户只看到“快捷键没反应”，后台捕获进程却会一直存在
并占住捕获锁。`Future.timeout` 不能可靠取消已经进入 FFI 的 worker isolate，因此超时后不能进入
带“重试”的普通失败面板，而要直接 `exitProcessNow()`，由操作系统同时清掉 worker 和捕获锁；
用户随后再次触发会得到一份全新的捕获进程。

`linux/runner/my_application.cc` 中已经移除了旧的 `first-frame` 自动 `gtk_widget_show()`。这是故意的：如果 native first-frame 回调再次显示窗口，捕获时机就会被破坏。

#### 失败态是两种，别混成一个开关

`CapturePage` 只有两种「不抓屏」的界面，且**互斥**：写点只有 `_showGuide()` 与
`_enterFailure()` 两处，改动这个状态机时不要把两者合回一个布尔。

```text
_needsPermission = true   权限缺失 → CapturePermissionGuide（macOS 语义：设置 URI、三步路径、重置授权记录）
_failureMessage  != null  普通失败 → 平台无关的失败面板（截图失败 + 重试 / 关闭，Esc 可关）
```

- 判定权限**必须**用安全查询 `_screenCaptureAuthorizedSafe()`（返回 `bool?`）：`null` 表示
  **查询本身失败**（dylib/符号问题），这时既不能当成“没授权”（Linux 会掉进 macOS 专属
  引导页——`rust/src/linux.rs` 的授权函数恒返回 1，所以 Linux 任何失败都会走到那条分支），
  也不能当成“已授权”（会直接去抓屏然后失败），只能进失败面板。
- `_capture()` 的授权预检在 `try` 内；`_showGuide()` 自己不许抛异常（授权请求与窗口显隐
  各自 try/catch），否则从 postFrameCallback / 轮询定时器里抛出去就是未捕获异步异常。
- 授权请求失败时**留在引导页**（“当前进程没有授权”这个判断仍然成立，系统设置出口仍有用），
  只有「授权查询失败」才切失败面板。
- `CapturePage.onAiAction` 是 `required` 的（唯一生产调用点在 `lib/app.dart` 永远传值），
  不要再改回可空 + 各处空判。

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
  Linux 优先 `$XDG_RUNTIME_DIR`），实际路径无关紧要，只要两份宿主看到同一个文件；
  `single_instance_guard.dart` 里还留了一条 Windows `%LOCALAPPDATA%` 分支，但 Windows
  平台本身未实现（见 §14），那里是 Flutter 模板遗留、跑不到的死分支；
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
        └── rust/src/macos.rs   CoreGraphics + ImageIO + NSPasteboard
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

#### 本机安装 / 本机 DMG

```bash
scripts/install_macos_app.sh                   # 构建 release + 装到 /Applications
scripts/install_macos_app.sh --dev-cert        # 用本地自签名证书签名（TCC 授权不再丢，见 6.2）
scripts/build_macos_dmg.sh --debug --install    # 构建 debug + 打 DMG + 装到 /Applications
```

`scripts/build_macos_dmg.sh --debug` 走的是同一套打包与验收流程，但**故意不换
Developer ID、不公证**：debug 需要 `get-task-allow`/JIT，hardened runtime 与公证对它没有
意义；产物名字带 `-debug` 后缀（`build/macos/HaxShot-<版本>-arm64-debug.dmg`），只用于
本机/内部联调，拿到别人机器上会被 Gatekeeper 拦。`--install` 会先退出正在运行的实例
（托盘宿主是常驻进程），再把 app 从挂载的 DMG 拷进 `/Applications` 并登记 LaunchServices。

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
Hax Shot 自己不会出现在“屏幕录制”列表里，于是怎么都授权不了。

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

#### 授权为什么会“丢”，以及丢了怎么救

本机（macOS 15.3.1）实测，TCC 给 ad-hoc 签名应用存下来的 requirement 是**裸 cdhash**：

```bash
# 看当前记录（需要终端有“完全磁盘访问权限”，否则读不了 TCC.db）
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select client,auth_value,hex(csreq) from access where service='kTCCServiceScreenCapture';"
# 我们的那条（去掉 8 字节头后）：version=1, op=cdhash(8), len=20, hash=2cc12dad…
```

只有 20 字节的二进制哈希、**不带 identifier 也不带证书**，所以：

- 每次重新构建 cdhash 都变 → 旧记录对不上（tccd 日志：
  `Failed to match existing code requirement for subject com.github.xiehanff.haxShot and
  service kTCCServiceScreenCapture`）→ 开关看着是开的，进程还是没权限；
- `tccutil reset ScreenCapture com.github.xiehanff.haxShot` 会把记录删掉。之后系统**不一定**
  再弹授权框（同一个 app 的弹框有节流），而“录屏与系统录音”面板只列有记录的应用 →
  列表里就彻底看不到 Hax Shot 了，用户没有任何入口去勾选。

恢复办法（都不需要重启）：

```text
系统设置 → 隐私与安全性 → 录屏与系统录音 → 列表下方的 “+”
    → 选 /Applications/hax_shot.app → 开关打开
```

`+` 是有的（15.3 实测，位于屏幕录制列表底部）；加完之后
`SecurityPrivacyExtension` 会弹那个“「hax_shot.app」想要录制此电脑的屏幕和音频”的系统框，
点“打开系统设置”就会把它登记进列表。引导页的步骤 2 和“重置授权记录”的提示里都写了这条。

实测（macOS 15，2026-09）：`tccutil reset` 之后 hax_shot **仍然留在列表里，只是开关变成
关的**（同一列表里其他 app 都是开的），这时直接把那个开关打开就行，不需要走 `+`。

#### 想“构建多少次都不用重新授权”

用固定证书签名（自签名即可，TCC 绑「bundle id + 证书」而不是 cdhash）：

```bash
scripts/macos_dev_cert.sh --trust      # 建证书 + 标成“信任用于代码签名”（弹一次系统授权）
scripts/install_macos_app.sh --dev-cert
```

两个坑：

- Homebrew 的 OpenSSL 3 导出的 PKCS#12 是 AES-256/SHA-256，`security import` 会报
  “MAC verification failed during PKCS12 import”；脚本现在加了 `-legacy` 并在不支持时回退。
- 自签名证书默认是 `CSSMERR_TP_NOT_TRUSTED`，`security find-identity -v` 里不算有效身份，
  `codesign --sign "Hax Shot Dev"` 会报 “The specified item could not be found in the
  keychain.” —— 必须先 `add-trusted-cert -r trustRoot -p codeSign`（就是上面的 `--trust`）。
  这一步要弹系统授权，脚本不能替你点。
- 证书放在独立 keychain 里时，还必须把该 keychain 加进**用户 keychain 搜索列表**。
  `codesign` 只在搜索列表里的 keychain 中查找签名身份，**只传 `--keychain` 不够**：即使
  `security find-identity -v -p codesigning <keychain>` 能列出这个身份，`codesign --sign`
  依旧报“The specified item could not be found in the keychain.”。
  `install_macos_app.sh --dev-cert` 现在会自己幂等地补这一步；另外
  `macos_dev_cert.sh --trust` 里导出证书原本写成 `security find-certificate -k <keychain>`，
  `-k` 不是合法选项（keychain 只能当位置参数），会直接报 illegal option——已修。

切到证书签名之后，TCC 里那条记录的**形态**会变，可以查出来确认（见上文的读取命令）：

```text
ad-hoc：000000010000000800000014 <20 字节裸 cdhash>              ← 一重建就失配
证书  ：FADE0C… com.github.xiehanff.haxShot … <证书 SHA-1>      ← 不含 cdhash，重建不掉
```

第二条里那个 40 位十六进制就是证书指纹，和 `security find-identity -v -p codesigning
"$HOME/Library/Keychains/hax-shot-dev.keychain-db"` 列出来的对得上就说明已经绑到证书了。

安全提示：`--trust` 会往用户信任设置里加一条代码签名信任，而该私钥所在 keychain 的密码是固定的
（`hax-shot-dev`）——只在本机开发用，不用了就 `scripts/macos_dev_cert.sh --delete` 并删掉信任项。

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

首次启动时如果没有已保存的绑定，会写入并使用默认值 `<Alt><Shift>z`（即 `⌥⇧Z`）——
菜单栏图标可能被 Bartender 之类的工具收进隐藏区，所以必须有一个不依赖图标的入口。
历史上自动写入过的旧默认值（`<Alt>z`、`<Super><Shift>z`）会在启动时迁移到当前默认值，
确保已有安装也立即生效；用户自己在设置页录制的组合键不会被改掉。

读取/写入偏好设置都带 2 秒超时（`_preferenceTimeout`）：偏好层故障时退回内置默认值，
仍然把热键注册上。这不是多余的防御——已经实测复现过：直接用 `rm` 删掉
`~/Library/Preferences/com.github.xiehanff.haxShot.plist`（而不是走 `defaults delete`）
会让 cfprefsd 留着坏掉的 domain，下一次启动的 `SharedPreferences` 调用**永远不返回**，
表现为“菜单栏能用、快捷键完全没反应、偏好设置里什么都没有”；再启动一次就自愈。
所以 `scripts/uninstall_macos_app.sh` 清偏好必须用 `defaults delete`，不要改成 `rm`。

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
<Alt><Shift>z     →  macOS ⌥⇧Z
<Alt>z            →  Linux Alt+Z
```

热键**不走 FFI**：macOS 由**宿主进程**的 `hotkey_manager` 注册（底层 Carbon
`RegisterEventHotKey`），Linux 不动、由 GNOME gsettings 直接启动 `hax_shot --capture`；
Rust 原生层不参与热键注册，`--capture` 进程也不注册热键。

#### 排查“快捷键没反应”先分叉，别直接查热键

菜单栏的「立即截屏」和全局快捷键最终调的是**同一个 `_startCapture()`**，所以先点一次
菜单就能一步分叉，不用猜：

| 菜单「立即截屏」 | 全局快捷键 | 结论 |
| --- | --- | --- |
| 能截图 | 没反应 | 问题在宿主进程的热键注册 / 回调 |
| 也没反应 | —— | **不是快捷键问题**，去查 `--capture` 与屏幕录制授权（见 6.2） |

本机实测过的那次“⌥Z 没反应”，最后查出来是第二类：热键本身一直是好的（按下去能跑到
`_startCapture()`、子进程也起来了），真正卡住的是抓屏进程拿不到屏幕录制授权。

另外两个容易误判的点：

- `hotkey_manager_macos 0.2.0` 的 Swift `register()` **无条件 `result(true)`**，它不检查
  soffes/HotKey 内部 `RegisterEventHotKey` 的返回值。所以 Dart 侧
  `await hotKeyManager.register(...)` 正常返回**不等于**系统真的记住了这个组合。
- Carbon 的 `RegisterEventHotKey` **跨进程不独占**：别的 app 已经占了同一个组合，本进程
  注册依然返回 `noErr`。所以“用探针试一下能不能注册”不能用来判断热键是否被占用。

真要定位时，先看抓屏进程有没有起来（`pgrep -f -- '--capture'`），再给 `_startCapture()`
临时加文件日志。从 Finder 启动的 Release 版 `stdout` 落到 launchd，`debugPrint` 看不到，
所以这类环境差异只能写文件。

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

这个顺序只由 Rust 实现一次（`resolve_target_display`），Swift 不再自己算：

```text
rust/src/macos.rs                  resolve_target_display() → C ABI hax_shot_target_display
macos/Runner/CaptureDisplay.swift  dlopen 调用 hax_shot_target_display，只把 id 映射成 NSScreen
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
    └── Swift：CaptureDisplay.targetScreen() 调 Rust 拿同一块屏，把浮层铺上去
```

DPI：抓屏是物理像素，浮层是该显示器的逻辑尺寸，`ScreenshotLayout.fromViewport` 会自动
算出 `scale`（Retina 2x 屏上是 0.5），裁剪、标注、导出仍然按物理像素计算。混合 DPI
（内置 2x + 外接 1x）不需要特殊处理，每次截图只涉及一块屏。

**不做的**：不支持一次框选跨越两块屏。macOS 开了「显示器有独立 Space」（默认）时
WindowServer 会把窗口限制在一块屏上，跨屏选区必须为每块屏各开一个浮层窗口（Capso、
Snapzy、better-shot、flameshot 都是这个架构），属于独立的一步；详见
[`docs/reference-decisions.md`](./reference-decisions.md)。

#### 调试 UI 入口

托盘菜单在 debug 构建里（`lib/app.dart` 里用 `kDebugMode` 控制）多出一组 **“调试：…”**
入口，把每个界面单独列出来，不用真的截图 / 等授权就能直接打开：

```text
调试：欢迎页          FirstRunGuide（不写“已看过”标记，每次都能重看）
调试：快捷键设置      ShortcutSettingsPage
调试：权限引导        CapturePermissionGuide（不影响真实权限状态）
调试：截图浮层        hax_shot --capture（和“立即截屏”同一条路径）
调试：AI 对话窗口      hax_shot --capture --debug-ai
```

`--debug-ai` 只在 debug 构建的托盘菜单里用到：捕获进程启动后不抓屏，直接把窗口
配成 AI 面板尺寸（456×680）显示出来，用于调 AI 面板的 UI。“我已授权，重新检查”
在调试模式下只反馈当前真实授权状态。

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

这个测试是 **app-hosted** 的（`@testable import hax_shot`，宿主就是应用本体），所以本地跑它有三条硬要求，不然报的错跟真实问题毫无关系：

```bash
# 1. 先让 Flutter 生成 macos/Flutter/ephemeral/*.xcfilelist 和 Pods 的文件列表：直接
#    xcodebuild 会报 “Unable to load contents of file list”（flutter pub get 不够）。
#    用 --config-only 就够：只生成配置 + 跑 pod install（几秒），Debug app 交给下面的
#    xcodebuild test 自己编；先整包 `flutter build macos --debug` 会白花约两分钟。
fvm flutter build macos --config-only --debug
# 2. 必须 Debug 配置：Release 关掉了 testability，会报 “not compiled for testing”
# 3. 先退出正在运行的 Hax Shot：单实例锁会让宿主 app 启动即退出，
#    XCTest 只会说 “Early unexpected exit / Test crashed with signal kill”
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

抓屏成功后 `becomeOverlay()` 会把它切成 `[.borderless]`：全屏浮层必须铺满屏幕、盖住
菜单栏和 Dock，不能有圆角。`exitOverlay()` 再切回面板外观。

Linux 的窗口本身没有圆角，靠 `RoundedWindow`（`ClipRRect`，半径 12）裁一刀 +
窗口背景透明做出圆角；这个平台上它才生效（见 `rounded_window.dart`）。

前提是**窗口底色真的透明**：`lib/main.dart` 里是
`backgroundColor: Platform.isMacOS ? Colors.black : Colors.transparent`。macOS 保持黑
（系统已经裁了圆角，透明反而会露出 NSWindow 底色/桌面，浮层也依赖不透明底兜底），
Windows/Linux 用透明，否则 `ClipRRect` 剪掉的四角露出的是一块黑角。全屏浮层不受影响
（它自己画满冻结画面）。这条改动没有 Windows/Linux 实机验证过。Windows 平台未实现
（见 §14），那里同样的分支只是 Flutter 模板遗留。**截图浮层
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

- 快捷键触发时 Hax Shot 通常不是前台应用；`becomeOverlay()` 必须先
  `NSApp.activate(ignoringOtherApps: true)`，再由 Dart `show()`。不能继续依赖
  `window_manager.show()` 里“先显示、后异步激活”的顺序，否则 AppKit 可能把已经抓完屏的浮层
  排到当前应用后面，用户看到的就是快捷键没反应；
- Esc 有**原生兜底**：`CaptureOverlayWindow.installEscapeMonitor()` 装 local monitor，
  窗口覆盖整屏时直接 `_exit(0)`。不依赖 Flutter 焦点树，也不依赖 `performClose`
  （后者对无边框窗口不一定生效）。但如果重复触发叠了多层浮层，每次 Esc 只能结束最上面
  一个进程，看起来仍像“Esc 失效”；所以 `main.dart` 的捕获分支必须先取得捕获专用文件锁，
  拿不到就在窗口插件初始化前硬退出。
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

### 欢迎页 / 授权引导的面板视觉

`lib/features/window/panel_chrome.dart` 是这两个“临时小窗口”的共用视觉层（首次欢迎页
`first_run_guide.dart`、授权引导 `capture_permission_guide.dart`）：

```text
窗口尺寸   欢迎页 560×460（居中开场版式刚好铺满）
           授权引导 560×480（内容实测 474pt，400 高会把底部“重置授权记录”说明藏到滚动区外）
           两个尺寸分别在 lib/app.dart 的 _showFirstRunGuide / _openPermissionGuide，
           以及 lib/main.dart 的捕获模式 WindowOptions 里，改一处要同步另一处
底色       PanelColors.bg = #101418       卡片 PanelColors.card = #171C22 + 1px 描边
强调色     PanelColors.accent = haxAccent（灰蓝），实心主按钮 / 图标徽标 / 提示条
顶部条     PanelHeader：整条 DragToMoveArea 可拖；传 icon/title 是“徽标 + 标题”头部，
           不传就是只留拖拽区 + 关闭（欢迎页的居中开场就是这个）
卡片       PanelCard（圆角 14 + 描边）/ PanelFactRow / PanelDivider
提示条     PanelNote：muted（终端说明）/ accent（状态）/ danger（错误）
开场版式   欢迎页：居中 56px 徽标 + 20px 标题 + 说明 + 卡片 + 居中按钮（填满 460）
```

三个约束别碰：

- **`PanelHeader` 的内容行必须包在 `Positioned.fill` 里**。`Stack` 的非定位子节点是按
  `alignment`（默认 top-start）**顶部对齐**的，直接把 `Row` 塞进 `Stack`，行只会占自身
  高度（徽标/关闭按钮那么高）并贴在窗口第一行——标题字面离窗口顶只有 ~9pt，看着就是
  “标题贴着窗口”。包成 `Positioned.fill` 后行拿到 header 的全高，再由 `Row` 自己的
  `crossAxisAlignment.center` 垂直居中（68 高 → 徽标顶 17pt，标题行盒顶 24pt）。

- 顶部条里标题那一行必须套 `IgnorePointer`，`Text` 会吃掉 hit test，不套就拖不动窗口；
- 一个页面只能有一个 `Icons.close`（`test/capture_permission_guide_test.dart` 断言
  `findsOneWidget`，退出只靠右上角 ✕，不要再加“退出”按钮）。

授权引导的按钮从原来的“实心姜黄 + 描边 + 纯文字”改成灰蓝实心主操作 + 描边 +
纯文字次操作，`_checking` / `_resetting` 的转圈逻辑不变；步骤列表改成数字徐标 +
正文（正文里不再写 “1. ”），所以那个测试断言的是步骤文案本身。

### AI 面板顶部条

`lib/features/ai/views/widgets/ai_sidebar.dart` 的 `_AiTitleBar` 中间放 `HaxShot` 字标，
字体是 `assets/fonts/GBaiMarkerPen.ttf`（从 cliper 项目复制的马克笔手写体，pubspec 里
声明为 `GBaiMarkerPen`；文件内部 family 名叫 “851 GBai Marker”，用别名即可。
字体是**随仓库分发的第三方资产**（10.3 MiB，`assets/fonts/GBaiMarkerPen.ttf`），来源与
许可状态记在 `THIRD_PARTY_NOTICES.md`；许可文本补齐前不要对外分发）：

```text
高度       66 → 44
底色       AppColors.titleBarBg = #0C0D11（比正文 scaffoldBg = #121318 更暗）
字标       HaxShot，GBaiMarkerPen 21px，颜色 AppColors.accentBright（灰蓝）
关闭按钮   top: 10 / right: 16
```

整条仍然是 `DragToMoveArea`（窗口没有原生标题栏），但字标要套 `IgnorePointer`：
`Text` 自己会吃掉 hit test，不套的话按住标题那一段拖不动窗口。macOS 的窗口圆角由
系统的 titled 窗口画，顶部条铺满即可，见 [窗口圆角](#窗口圆角)。
`test/ai_panel_chrome_test.dart` 守着顶部条存在、且 `titleBarBg` 与 `scaffoldBg` 不同。

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
| `linux/icons/hax_shot.png`、`linux/icons/com.github.xiehanff.hax_shot.png` | 手工保留的 256px 兼容副本：`scripts/generate_icons.sh` 不生成它们，也没有任何构建引用 |

更换图标后必须同时完成：

```bash
fvm flutter build linux --release
./scripts/install-gnome-shortcut.sh
```

正在运行的托盘进程通常已经缓存了旧图标，必须退出并重新启动 Hax Shot；只替换 PNG 文件不一定会立即刷新已经显示的 AppIndicator 图标。

### 主题色（`lib/hax_colors.dart`）

`haxAccent = #8FAEC9`，灰蓝。图标（`assets/icons/hax_shot_source.png`，主色
`#7387A6`）和 app 内主题现在都是灰蓝：以前取图标主色的亮姜黄 `#F8C800`，**app 内一律
不再用姜黄**。`#8FAEC9` 比图标主色亮一档，深色底上做按钮底色对比度才够；配
`_onHaxAccent = #101A24`：灰蓝底色上文字/图标要压暗才看得清。`haxAccentTheme(base)` 只覆盖
`FilledButton` 的 backgroundColor / foregroundColor 和 `OutlinedButton`/`TextButton` 的
前景色，不动 `colorScheme`。

`MaterialApp` 的 `ColorScheme.fromSeed` 也用 `haxAccent` 作种子（原来是 `Colors.lightBlue`）。
欢迎页/授权引导不再走主题色，而是用 `panel_chrome.dart` 里显式的 `PanelButtons`
（主按钮也是 `haxAccent`），所以种子色只影响还没改成面板样式的页面（设置页等）。
AI 面板的 `lib/features/ai/views/widgets/ai_colors.dart` 同样把 accent 系列从偏紫的
靛蓝换成了灰蓝。

**同源的值只存一份**（`lib/hax_colors.dart` 是源头）：`haxTextPrimary(#F2F4F7)` 与
`haxAccentBright(#9DBBD6)` 在 `PanelColors.title/accentText` 和 `HaxAiColors.textPrimary/
accentBright` 里都是引用，不再各写一份 16 进制字面量；`PanelColors.accentSoft/accentBorder`
由 `haxAccent.withValues(alpha: 0x1F/255 | 0x33/255)` 派生（与原字面量 `0x1F8FAEC9` /
`0x338FAEC9` 精确等值）。反过来让 `panel_chrome.dart` 当源头不行：它 import 了
`window_manager`，被 AI 面板引用会把窗口插件拖进那边的 import 图。改色时只改
`hax_colors.dart`，改完检查这两处引用方；`chat_bubble.dart` 里已不再有 `#98B8FF` /
`#343A46` / `#B8C0CC` 这类旧字面量。

现在只剩设置页还在用 `haxAccentTheme`，欢迎页/授权引导已经改用 `panel_chrome.dart` 的
`PanelButtons`，其余页面保持默认深色主题：

```text
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

GitHub Actions 配置位于 `.github/workflows/release.yml`，只在推送 `v*` tag 时运行（`workflow_dispatch` 用于不发布的干跑）。普通 `main` push 和 PR 只跑 `verify.yml`：Linux job 负责 analyze / Dart 测试 / Rust 检查 / Linux 构建，macOS job 负责 Dart 测试 / Rust 检查 / `RunnerTests`（XCTest）/ `flutter build macos --release`。macOS job 在跑 XCTest 前用 `flutter build macos --config-only --debug` 生成 xcfilelist（不编译 app），Debug app 直接由 `xcodebuild test` 构建——不要再加一步整包 `flutter build macos --debug`。`verify.yml` 的 `push` 触发器带 `paths-ignore: ['pubspec.yaml']`：发布提交只改版本号，紧接着就会被 tag 的 Release workflow 构建，不需要再跑一次 Verify。

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

推送 tag 后，工作流会先校验 tag 与 `pubspec.yaml` 版本一致，再分别构建 macOS arm64 DMG、Debian/Ubuntu DEB 和 Fedora RPM，最后把三个包一起上传到对应的 GitHub Release。不要为普通开发 commit 创建 `v*` tag；改打包链路要先 `gh workflow run release.yml` 干跑。macOS 签名策略是“要么签+公证，要么叫 `-unsigned` 并在 Release 正文加警告”，证书和凭据 secret 见 [`ci-release.md`](./ci-release.md)。

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
- 菜单栏直接用应用图标（`assets/icons/hax_shot.png`，18pt）。深色菜单栏上对比度偏低，但这是产品要求，
  不要再改成单色 template；
- 还没有 DMG 打包、公证（notarization）和 `AppIcon`（仍是 Flutter 默认图标）；
- 还没有 macOS 的 CI 构建任务，本地验证使用 `fvm flutter build macos`；
- 不支持跨显示器框选：一次截图只覆盖目标显示器，选区不能跨越两块屏。

Windows（未实现）：

仓库里只有 Flutter 的模板脚手架（`windows/`，含 `app_icon.ico`）、`assets/icons/hax_shot.ico`
与 `pubspec.yaml` 的 `.ico` 资源声明，以及几处平台分支（`lib/app.dart` 的 trayIconAsset、
`single_instance_guard.dart` 的 `%LOCALAPPDATA%`、`local_image_attachment_loader.dart` 的
`toFilePath(windows:)`）；Rust 后端（`rust/src/lib.rs` 只编 linux/macos，`Cargo.toml` 只有这
两个 target 的依赖）、Windows 构建规则、`NativeBridge` 的 `.dll` 查找都缺，
`flutter build windows` 不可用。历史上 `c7a65ec` 的提交信息写过“新增 Windows 支持”，与
实际不符，以本节为准；要真正支持需另立项目，先定抓屏 API（BitBlt/PrintWindow vs DXGI）
与多显示器/窗口时序方案。

两个平台共同：

- 暂不捕获鼠标光标；
- 暂不支持 OCR、贴图、持久化会话、录屏和滚动截图；AI 会话仅在当前进程内保留；
- 快捷键每次启动独立 `--capture` 进程，但同一时间只允许一个进程进入全屏捕获：
  `lib/main.dart` 的捕获分支调用 `acquireCapture()`，拿不到捕获专用文件锁就在窗口插件初始化前
  `exitProcessNow()`。捕获锁检查失败必须 fail-close，宁可少截一次也不能叠全屏窗口。进入普通
  AI 面板后释放锁，用户仍可开始下一次截图；授权后重启则由旧进程持锁启动带
  `--capture-handoff <旧 PID>` 的接替者。接替者先持有预约锁并写 ready 文件，旧进程确认后才
  硬退出；预约期间普通快捷键进程直接退出，不能争抢刚释放的捕获锁。这个约束不能删，
  否则一次重复菜单/热键事件会叠出多个 `.screenSaver`
  浮层，每按一次 Esc 只退出一层，表现成主屏卡死；
- 托盘宿主也有单实例保护（`lib/features/app/single_instance_guard.dart`）：`lib/main.dart`
  的非 `--capture` 分支调 `acquire()`，用的是内核级文件锁（`FileLock.exclusive`，非阻塞），
  拿不到就直接 `exitProcessNow()`；`lib/app.dart` 的 `_quit()` 在最后调 `release()`。**没有它会出现
  “从托盘退出后按快捷键还能截图”**——两份宿主各自注册了进程内的全局快捷键，退出的只是
  其中一份。不要改成“记 PID + SIGTERM”：有竞态和 PID 复用误杀的风险。Linux 上同类问题是
  gsettings 里的快捷键指向旧的 release 路径，要重跑 `scripts/install-gnome-shortcut.sh`；
- Linux 需要运行 `scripts/install-gnome-shortcut.sh` 安装默认快捷键；macOS 首次启动会自动注册 `⌥⇧Z`，也可以在设置页重新录制。

## 15. 给后续 Agent 的最短交接信息

如果任务是调整捕获 UI：只改 `lib/features/capture/`，保持 `_capture()` 完成后再 `windowManager.show()`。
这一层已经按职责拆过（评审后落地）：`capture_permission_flow.dart`（`CapturePermissionFlow`，
权限/失败状态机与轮询，`ChangeNotifier`）、`capture_process_lifecycle.dart`（抓屏进程启动/退出/重启
与窗口生命周期）、`text_annotation_state.dart`（文字标注编辑状态）、`text_annotation_style.dart`
（字号/高度/测量规格，`capture_page.dart`、`screenshot_canvas.dart`、`text_annotation_editor.dart`
都用它，不要再各写一份）；`capture_page.dart` 只留编排与 UI（约 545 行），不要再往里塞窗口、
进程或轮询职责。

如果任务是调整托盘：只改 `TrayHostPage`，不要添加主应用窗口；截图必须通过 `--capture` 子进程启动。

如果任务是调整截图后端：先阅读 `docs/snapclip-source-review.md`，保持 Mutter ScreenCast 的调用顺序，不要替换为 Screenshot Portal。

如果任务是多显示器：先读 [6.9 多显示器](#69-多显示器)。macOS 的选屏规则（`--display` →
光标 → 主屏）只在 `rust/src/macos.rs` 的 `resolve_target_display()` 里实现一遍，Swift 通过
`dlopen` 调 `hax_shot_target_display` 取 `CGDirectDisplayID`；改规则只改 Rust，不要在
`macos/Runner/CaptureDisplay.swift` 里重抄一遍候选顺序。Linux 需要多窗口架构，不能只改抓屏。
要支持跨屏框选，必须改成“每块屏一个浮层窗口 + 跨窗口选区同步”，不要试图用一个窗口去跨屏。

如果任务涉及托盘/菜单栏图标：macOS 菜单栏用**应用图标本身**（`assets/icons/hax_shot.png`，
`setIcon` 不传 `isTemplate`），Linux 同一张 PNG，Windows 用 `hax_shot.ico`。有人试过改成单色
template 方案（`isTemplate: true` + 单色遮罩图），被要求改回：菜单栏图标必须和应用图标一致，
不要以“深色菜单栏看不清”为理由再引入第二张图标。详见 [`docs/icon-and-tray.md`](./icon-and-tray.md)。

如果任务是调整图标/Dock 匹配：先检查 application ID、desktop 文件名、`Icon` 名称和 `StartupWMClass`，再用 `icns-handle` 生成图标、运行安装脚本并重启旧进程；Wayland 下 GNOME Dock 仍使用旧缓存时需要注销并重新登录。

如果任务是增加跨平台支持：先明确不能把当前 Mutter/GStreamer 路径抽象成所有 Linux 桌面的通用方案；应新增后端并保留 GNOME backend，参考 `rust/src/macos.rs` 的做法：平台实现只暴露 `capture_screen_impl` / `copy_png_impl` / `cursor_display_impl` 等函数（热键不在其中，见 §6.6）。

如果任务是调整 AI 面板/侧栏：`HaxAiController` **由宿主显式持有**（`lib/app.dart` 里
new 出来、`dispose()` 里 `_aiController?.dispose()`），**不走 GetX registry**——不要加回
`Get.put`/`Get.find`/`Get.delete`。控制器构造函数里自己做了
`$configureLifeCycle() + onStart()`（GetX 的生命周期原本只在 `Get.put` 路径里启动，少了
这步 `onInit()` 不会跑）；`dispose()` 走 `onDelete()`（它才置 `_isClosed`，`onClose()` 是
空实现），`isClosed` 还被 `_disposed` 护了一层。侧栏用 `ListenableBuilder` 订阅
`update()` 的通知（`GetxController.addListener` 注册的就是 `update()` 通知的那份列表）。
交互契约 `HaxAiAction` 在 `lib/models/hax_ai_action.dart`（不在 `features/ai/` 下，capture
不再反向依赖 ai 模型）。错误占位消息用 `ChatMessage.isError` 判断，**不要解析 `❌` 文案前缀**。

如果任务是改 `packages/plume_ai_chat`：它是**公开 API**（0.2.0 起删掉了
`prepareSubmission` / `fallbackBuilder` / `presentLocalError` / `canFallbackToText` 与
`AiChatUpdateId.settings`，见包内 CHANGELOG）。`stopPrevious` / `deferHistoryCommit` 是宿主
在用的参数、`send()` 自己会填 `displayText/displayImageBytes`，不要顺手删。

一句话记忆：**先确定这是 tray 宿主还是 `--capture` 窗口，再修改对应层；不要让隐藏时序、desktop ID 或 ScreenCast 顺序被无意破坏。**
