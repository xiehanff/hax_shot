# HaxShot 当前实现与后续开发指南

> 这份文档记录的是**当前代码已经实现的行为**，不是最初的设计草案。后续 Agent 开始改 UI、截图流程或 Linux 集成前，应先读本文件；参考仓库与许可证约束见 §17，图标与托盘见 §11。

文档地图：**只有四份**（不要再加）——用户向的 [`README.md`](../README.md)、本文件（代码怎么跑、
改哪里、别碰什么）、[`packaging.md`](./packaging.md)（打包与发布）、[`rust/README.md`](../rust/README.md)。
这里只写约束和踩过的坑，不写原理介绍。

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

HaxShot 是一个 **tray-only** 应用：普通进程没有主应用窗口，只有托盘图标（Linux GNOME 托盘 / macOS 菜单栏）和托盘菜单。

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
Alt+Shift+Z / 托盘“立即截屏”
    ↓
启动一个新的 HaxShot --capture 进程
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
| `lib/features/capture/capture_toolbar.dart` | 磨砂玻璃工具条、HugeIcons 图标和标注工具 | 保持全圆角胶囊、纯白图标、BackdropFilter；**不要边框**，悬浮感靠最外层 Container 上两层向下的阴影（blur 28/offset 0,14 + blur 8/offset 0,3），阴影必须画在没有祖先 ClipRRect 的那一层，否则会被裁掉；矩形/箭头/文字工具通过 callback 切换，颜色由 CapturePage 持有并用于预览和最终 PNG |
| `lib/features/capture/screenshot_canvas.dart` | 图片适配、遮罩、选区和矩形/箭头/文字绘制、point→pixel 映射 | `ScreenshotLayout` 的坐标是 Flutter logical pixels，最终裁剪和标注导出是物理像素 |
| `lib/native/native_bridge.dart` | Dart FFI 封装 | 不在这里执行 DBus 或 `wl-copy`，这些都属于 Rust 原生层 |
| `rust/src/lib.rs` | Mutter ScreenCast、GStreamer、`wl-copy`、C ABI | 不要悄悄回退到 Screenshot Portal，否则会重新出现 GNOME 快门声 |
| `linux/runner/my_application.cc` | GTK 窗口、应用 ID、开发桌面项 | Dart 负责显示/隐藏；不要恢复旧的 first-frame 自动显示逻辑 |
| `linux/CMakeLists.txt` | Flutter bundle、Rust 库、desktop 文件和 hicolor 图标安装 | Rust 动态库和系统 GStreamer 插件是两套不同依赖 |
| `scripts/install-gnome-shortcut.sh` | 安装 `Alt+Shift+Z` 和用户 desktop/icon | 改快捷键或图标后要重新运行此脚本 |

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

因此调 UI 时如果只运行普通命令，看不到窗口是正常的。要看框选 UI，可以按 `Alt+Shift+Z`，或运行：

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

#### `capture_ready` 与 `overlay_ready` 不是一回事

```text
capture_ready   图像已解码、可以开始交互（原语义，宿主现有轮询不改）
overlay_ready   becomeOverlay() + showWindow() + focus() 都完成，浮层真的摆好了
```

宿主**不能**用 `capture_ready` 推断“窗口已正确显示”（Windows 上 `becomeOverlay` 失败时图像
已经有了，但浮层没摆成）。`overlay_ready` 的一条日志里同时带物理契约数据：原生
`GetClientRect`、冻结的 rcMonitor、PNG 尺寸、Flutter 的物理/逻辑 viewport 与 dpr，
`contract_ok=false` 时要先查窗口链路（Windows 见 [18.14](#1814-phase-3多显示器浮层与窗口所有权)），
不要给选区加补偿边距。失败时写的是 `overlay_become_failed`（带 native code），不是
`overlay_ready`。

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

`lib/app.dart` 的 `_initializeDesktopIntegration()`：

```text
lib/app.dart _initializeDesktopIntegration()
_initializeWindowSafely()      ← setPreventClose / hide / endOfFrame
    → _initializeShortcutSafely()  ← 全局快捷键（macOS 走一次 Carbon）
    → _initializeTraySafely()      ← 图标 + 菜单
    → _initializeWelcomeSafely()   ← 欢迎页
```

**快捷键排在托盘前面，不要按“图标要最先出现”的直觉调换。** 错误隔离 ≠ 卡死隔离：托盘
这一步要摸 AppKit 的 status item，一旦它挂住（拿不到临时 frame、缺 AppIndicator、
Plugin 卡在原生调用里），排在后面的快捷键注册就根本不会执行——这正是“按了没反应”
的成因之一。HaxShot 是截图工具：**快捷键可用 > 菜单栏显示快捷键文字**，托盘菜单晚
一拍显示状态完全可以接受。

配套的两条约束：

- 托盘菜单的标签只读**内存里的注册状态**（`activeBinding` / `configuredBinding`），
  **不读** `SharedPreferences`；
- 启动链上剩下的偏好读取（快捷键绑定、欢迎页标记）都带超时
  （`MacosShortcutService._preferences()`、`FirstRunOnboarding.timeout`），
  坏掉的 `NSUserDefaults` domain 不会把任何一步永久吊住。

**每个步骤都有自己的 `try/catch`（`_initializeXxxSafely`），互不阻断**。以前四步共用
一个大 `try/catch`，托盘图标建不出来会让后面的快捷键注册**根本不执行**，而 `catch` 里
只有一行 `debugPrint`——Release 用户看到的就是“快捷键没反应”。现在这四步各自失败只记
自己的 `*_init_failed` 事件。

### 3.5 截图触发链诊断日志

“按了快捷键什么都没发生”必须能从用户机器上一份日志里定位到**停在哪一层**。所有低频
关键事件走 `lib/features/diagnostics/diagnostic_log.dart`，JSON Lines 追加写入：

```text
macOS  ~/Library/Application Support/com.github.xiehanff.haxShot/logs/hax_shot.log
Linux  $XDG_STATE_HOME/hax_shot/logs/hax_shot.log（退回 ~/.local/state/...）
```

单文件 2 MB、最多保留 4 个（`hax_shot.log.1` …）。只记生命周期/状态/错误，**不记**截图
内容、OCR 文本、AI 对话、屏幕文本、API Key（敏感 key 由 `_redactedKeyFragments` 兜底
替换成 `[redacted]`，超长值截断到 1000 字符）。事件名与错误码是稳定契约，都在
`lib/features/diagnostics/diagnostic_events.dart`，改名等于把历史日志废掉。

两个实现约束，改的时候别退回去：

- **全部同步写**。宿主和 `--capture` 子进程都写同一个文件，异步排队会让同一进程内
  `log(A); log(B)` 变成 B 先落盘；同步 append 的开销在低频事件下可以忽略。
- **`append + rotate` 走 `<log>.lock` 的 OS 文件锁**。进程内的串行队列管不了跨进程：
  宿主和子进程可能同时判断“超过上限了”然后同时 rename。锁由内核维护，被 SIGKILL 也会
  自动释放。

一次正常截图（宿主 + 子进程共用同一个 `request_id`）：

```text
shortcut_trigger            ← 快捷键真的触发了；没有这一条就是 Carbon/注册/生命周期
capture_request_created     ← 宿主建了请求文件
capture_process_spawn_success
capture_child_started       ← 子进程 main() 跑到了；宿主靠它区分“没起来”
capture_lock_acquired       ← 子进程写的，以及宿主观察到的（observed_by: host）
capture_ready               ← 抓屏成功，浮层已铺满屏幕
```

宿主会把自己观察到的 ACK 阶段也记一遍（`observed_by: host`），所以**宿主日志单独就能
串出完整链路**，不用去子进程的 pid 里找那一行。

排查分叉（等价于 6.6 的菜单/快捷键对照表，但不用人肉复现）：

| 日志停在哪 | 故障层 |
| --- | --- |
| 只有 `shortcut_register_success`，没有 `shortcut_trigger` | Carbon 注册 / 生命周期 |
| 有 `shortcut_trigger`，没有 `capture_process_spawn_success` | 起子进程 |
| 有 `capture_process_spawn_success`，没有 `capture_child_started` | 子进程启动（参数 / runtime / bundle path / crash） |
| 有 `capture_child_started`，然后是 `capture_lock_busy` | 截图并发 / 捕获锁（正常业务状态） |
| 什么都没有 | 宿主根本没在跑（看进程 + 菜单栏图标） |

ACK 走 requestId 对应的小 JSON 文件（`capture_requests/<id>.json`），不引入 socket/IPC：

```text
宿主写 created（必须同步写，异步写会把子进程的 child_started 覆盖回 created）
子进程 main() 写 child_started → 拿锁写 lock_acquired / 失败写 lock_busy
抓屏成功写 capture_ready；抓屏失败写 startup_failed
```

宿主只等到 `lock_acquired`（默认 1.5s）就返回，**不等用户画完选框**；超时只记
`capture_launch_timeout`，不 kill 子进程（可能只是慢）。上一次运行留下的请求文件在下次
启动时清掉（超过 24 小时）。

宿主侧的职责收敛在 `lib/features/capture/capture_launcher.dart`（requestId / 参数 /
`Process.start` / ACK / 结果）：菜单和全局快捷键都调它，只有 `CaptureTriggerSource`
不同。快速连按时它自己 single-flight，第二次直接按 `lockBusy` 拒绝——**不**排队重试，
否则会变成进程风暴。

## 4. 无快门声截图管线

### 4.1 为什么不用 Screenshot Portal

`org.freedesktop.portal.Screenshot` 是标准授权接口，但 GNOME Wayland 的 Screenshot 路径可能播放截图闪光/相机声音。它适合普通“拍一张屏幕”的工具，不适合本项目的“先冻结、再框选”体验。

GNOME Shell 自己的截图 UI 使用 Mutter 内部的 `screenshot_stage_to_content()` 获取合成器内容，再在 Shell actor 上绘制遮罩。外部应用无法直接调用这个 Shell 内部对象，所以 HaxShot 使用 Mutter 对外的 ScreenCast D-Bus 接口复现同样的顺序。

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

#### 命名约定：哪些能跟着产品名改，哪些不能

产品名统一是 **HaxShot**（`PRODUCT_NAME` / `CFBundleDisplayName` / 安装路径
`/Applications/HaxShot.app` / 可执行文件 `HaxShot` / DMG 卷名）。但下面这些是跨进程、
跨语言或已经落盘的**标识**，改名只会砸自己的脚：

| 保持不变 | 为什么 |
| --- | --- |
| `com.github.xiehanff.haxShot` | bundle id 是 TCC 授权、偏好设置、单实例锁、LaunchAgent 的键；改了屏幕录制授权和用户配置全部作废 |
| `hax_shot --capture`（Linux） | Linux 二进制名由 `flutter build linux` 按 pubspec 的包名生成，`/usr/bin/hax_shot` 是 deb/rpm 的既定路径 |
| `hax_shot/shortcut`、`hax_shot/capture_window`、`hax_shot/lifecycle` | MethodChannel 名，Dart 与原生两侧必须一致 |
| `libhax_shot_native` / `hax_shot_target_display` | Rust dylib 名与 C ABI 符号，构建脚本和 `dlopen` 都按它找 |
| `hax_shot.capture_shortcut` | 偏好设置的 key（改了等于把用户的快捷键设置丢掉） |
| `hax_shot.lock` / `hax_shot_capture.lock` / `hax_shot.log` | 锁文件与日志文件名 |
| `Hax Shot Dev` | `scripts/macos_dev_cert.sh` 创建的本地签名证书身份名；改它要重新建证书并重新授权 |

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

脚本依次做：`fvm flutter build macos --release` → `pkill -x HaxShot` 结束旧实例（托盘宿主
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
HaxShot 自己不会出现在“屏幕录制”列表里，于是怎么都授权不了。

要调试权限相关功能，用 `open` 启动构建产物，让 HaxShot 成为责任进程：

```bash
scripts/run_macos_debug.sh            # 构建 debug 并用 open 启动
scripts/run_macos_debug.sh --release
# 等价于：
open build/macos/Build/Products/Debug/HaxShot.app
```

`flutter run -d macos` 仍然适合调 UI —— 前提是你的**终端**已经有屏幕录制权限，
这时子进程会继承终端的授权（不会弹窗、列表里也没有 HaxShot）。


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
    │             弹一次系统对话框 + 把 HaxShot 注册进“屏幕录制”列表
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
  列表里就彻底看不到 HaxShot 了，用户没有任何入口去勾选。

恢复办法（都不需要重启）：

```text
系统设置 → 隐私与安全性 → 录屏与系统录音 → 列表下方的 “+”
    → 选 /Applications/HaxShot.app → 开关打开
```

`+` 是有的（15.3 实测，位于屏幕录制列表底部）；加完之后
`SecurityPrivacyExtension` 会弹那个“「HaxShot.app」想要录制此电脑的屏幕和音频”的系统框，
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

#### debug 构建也要用证书签名

`flutter build macos --debug` / Xcode 直接跑 Debug 配置时，默认是 **ad-hoc 签名**
（`CODE_SIGN_IDENTITY = "-"`），于是上面那套「授权绑 cdhash、重建即失效、开关看着是开的
却没权限」在 debug 阶段每次都发生一遍——调权限相关功能时几乎没法用。

所以 `scripts/run_macos_debug.sh` 构建完会自动用 `Hax Shot Dev` 重签（保留
`get-task-allow` / JIT / `disable-library-validation` entitlements，debug 必须留着），
并先 `pkill -x HaxShot` 再 `open`，保证启动的是刚构建的那份。想复现 ad-hoc 的授权问题就加
`--ad-hoc` 跳过重签。

从 ad-hoc 切到证书签名时，旧那条授权记录对不上号，需要 reset 一次再重新授权：

```bash
tccutil reset ScreenCapture com.github.xiehanff.haxShot
```

之后 debug / release 都固定绑在证书上，改代码重建不用再授权。

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

macOS 没有 gsettings。全局热键**直接调 Carbon**，实现在
`macos/Runner/ShortcutBridge.swift`（Dart 侧 `lib/features/settings/macos_shortcut_bridge.dart`）。

**为什么不再用 `hotkey_manager` 注册**：`hotkey_manager_macos 0.2.0` 的 Swift
`register()` **无条件 `result(true)`**，而 soffes/HotKey 内部的 `RegisterEventHotKey`
失败时是静默 `return`。于是「Carbon 没注册上」和「注册成功」在 Dart 侧长得一模一样：
设置页显示“已启用”、用户按下去毫无反应。自建桥只做三件事——透传
`RegisterEventHotKey` / `UnregisterEventHotKey` 的真实 OSStatus、把按键转成 Dart 回调——
注册状态机仍然全在 Dart 里。

`hotkey_manager` 只保留用来把绑定字符串解析成 `HotKey` / `LogicalKeyboardKey`
（`lib/features/settings/hotkey_binding.dart`）。

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
macOS: Carbon 原生桥注册（macos/Runner/ShortcutBridge.swift，Dart 侧 MacosShortcutService）
Linux: 不动，GNOME gsettings 自己启动 `hax_shot --capture`
    ↓ 热键按下
onTriggered → 和点托盘菜单“立即截屏”同一条路径（读光标所在屏 → 起 --capture 子进程）
```

绑定字符串与 Linux 共用同一种格式，由 `lib/features/settings/hotkey_binding.dart` 解析：

```text
<Alt><Shift>z     →  macOS ⇧⌥Z（默认快捷键）
                  →  Linux Alt+Shift+Z（同一个绑定串：macOS 的 ⌥ 就是 Linux 的 Alt）
```

热键**不走 FFI**：macOS 由**宿主进程**的 `ShortcutBridge`（Carbon `RegisterEventHotKey`）
注册，Linux 不动、由 GNOME gsettings 直接启动 `hax_shot --capture`；Rust 原生层不参与
热键注册，`--capture` 进程也不注册热键。

#### 排查“快捷键没反应”先分叉，别直接查热键

菜单栏的「立即截屏」和全局快捷键最终调的是**同一个 `_startCapture()`**，所以先点一次
菜单就能一步分叉，不用猜：

| 菜单「立即截屏」 | 全局快捷键 | 结论 |
| --- | --- | --- |
| 能截图 | 没反应 | 问题在宿主进程的热键注册 / 回调 |
| 也没反应 | —— | **不是快捷键问题**，去查 `--capture` 与屏幕录制授权（见 6.2） |

本机实测过的那次“⌥Z 没反应”，最后查出来是第二类：热键本身一直是好的（按下去能跑到
`_startCapture()`、子进程也起来了），真正卡住的是抓屏进程拿不到屏幕录制授权。

Carbon 的 `RegisterEventHotKey` **跨进程不独占**：别的 app 已经占了同一个组合，本进程
注册依然返回 `noErr`。所以“用探针试一下能不能注册”不能用来判断热键是否被占用。

#### 一个反直觉的坑：必须用 `GetEventDispatcherTarget()`

`ShortcutBridge` 里 `InstallEventHandler` 和 `RegisterEventHotKey` 传的目标都必须是
**`GetEventDispatcherTarget()`**，不能用 `GetApplicationEventTarget()`。

本机实测过：用 `GetApplicationEventTarget()` 时两个调用都返回 `noErr`
（日志里 `shortcut_register_success` 一切正常），但按 ⌥⇧Z 处理器**一次都不会被调用**——
因为 application target 是 Carbon 自己那套 `RunApplicationEventLoop()` 的投递目标，而
Flutter 用的是标准 `NSApplication` 事件循环。soffes/HotKey 用的就是
`GetEventDispatcherTarget()`，这也是为什么老实现能工作。

> 顺带一条：`shortcut_register_success` **只表示 Carbon 接受了这个组合**（`noErr`）。
> 想验证“按下去真的会响”，看 `shortcut_trigger`。

#### 睡眠/唤醒后热键会“注册着但不投递”

实测（`pmset displaysleepnow` 复现，稳定命中）：显示器睡眠再唤醒后，⌥⇧Z 完全没反应。
但此时：

- `probe`（同进程重复注册同一组合）返回 `eventHotKeyExistsErr(-9878)` → **系统仍然认为
  这个热键注册在我们进程上**；
- 我们持有的 `EventHotKeyRef` / `EventHandlerRef` 都还在；
- 手动 `InstallEventHandler` 重装一遍 handler **没有任何用**；
- 只有真正 `UnregisterEventHotKey` + `RegisterEventHotKey` 才能恢复投递；
- **重启进程一定能恢复**（新进程的注册一定是好的）。

结论：睡眠会作废热键绑定的那个**事件投递目标**，注册表里那条记录还在、事件却被丢掉；
重装 handler 救不了（handler 装在新的目标上，事件还发给旧目标），必须重新注册才能把热键
绑到当前目标上。

所以 `lib/app.dart` 的 `_recoverShortcut()` 对唤醒类事件（wake / unlock / session-active）
排了一个**重注册梯度**（+2s、+6s 各补一次），而不是只试一次：实测唤醒后 +3s 那次没救回来，
稍后再做一次就好了。`app_resumed` 太频繁，不排梯度。

配套的两条约束别改回去：

- 必须用 `GetEventDispatcherTarget()`（见上一节），`GetApplicationEventTarget()` 在这个
  应用里注册返回 noErr 但永远收不到事件；
- 唤醒类事件后的重注册要一直保持是**真正的注销 + 注册**，不要为了“省事”改成只重装
  handler —— 那只会在日志里显示成功，实际热键依然是死的。

#### 怎么在没有真键盘的情况下验证全局热键

合成按键是可以触发全局热键的，用 `CGEvent.post(tap: .cghidEventTap)` 即可，但**必须**：
poster 跑真正的 `NSApplication` 事件循环（`app.run()`）、`CGEventSource` 用
`.combinedSessionState`、并且 poster 自己**不要**注册同一个组合（否则事件会被 poster
自己吃掉，结果没有判断力）。`osascript -e 'tell application "System Events" to keystroke'`
和 System Events 的 `keystroke` 对这条链路不可靠，别用它验证。

#### 注册状态、改绑事务与唤醒恢复

#### 注册状态、改绑事务与唤醒恢复

「配置里存着 ⌥⇧Z」和「系统当前真的注册了 ⌥⇧Z」是两件事，必须拆开：

```dart
enum ShortcutRegistrationStatus { inactive, registering, active, failed }
```

`ShortcutService` 现在对外暴露 `status / activeBinding / lastError / lastRegisteredAt /
registrationStatus(Listenable)`，`activate()` / `reactivate()` / `saveBinding()` 都返回
`ShortcutActivationResult`（sealed：Success / Failure）。**调用者必须检查返回值**：

- 托盘菜单多了一行只读项 `快捷键：⌥⇧Z（已启用 / 注册失败 / 未启用）`；
- 设置页把「当前快捷键（配置）」和「当前注册状态」分成两块显示；
- 只有拿到 `ShortcutActivationSuccess` 才算“已启用”，**写偏好设置成功不等于注册成功**。

改绑是事务（`saveBinding`）：注销旧 → 注册新 → 成功才写偏好；新绑定失败则把旧绑定注册
回去（`restoredBinding` 非空）；旧绑定也注册不上时 `status = failed`、`activeBinding = null`，
UI 必须显示“全局快捷键当前不可用”。因此 `_activeBinding` 在尝试改绑前就会清空——它表示
“当前真的注册了什么”，不是“配置里写了什么”。

原生桥返回的是真实 OSStatus，所以 `status = active` 现在表示 **Carbon 接受了这个
组合**（`noErr`）；失败会带上 osStatus 进日志（`extra.os_status`），常见值
`-9878 eventHotKeyExistsErr` 表示被系统保留或本进程已占用。启动注册失败会**有限重试
一次**（`retryDelay`），不做无限重试。

三个绑定概念必须分开，别混：

| 概念 | 含义 | 什么时候会不一致 |
| --- | --- | --- |
| `activeBinding` | 系统现在真的会响应的组合 | 注册失败时为空 |
| `configuredBinding` | 偏好设置里存着的组合 | 注册成功但偏好写失败时（返回 `Success(persisted: false)`） |
| `persisted` | 本次结果有没有写进偏好 | 写失败时 false，UI 显示“本次已生效但没能保存” |

托盘菜单和设置页显示的都优先是 `activeBinding`，并且会在两者不一致时把配置值也写出来；
**不能拿配置当“当前快捷键”**。

`clearBinding()` 返回 `bool`：注销失败或配置没删成时返回 false，UI 不允许报“已删除”。
注销失败还会中止本次改绑（`SHORTCUT_UNREGISTER_FAILED`），因为那时旧 Carbon handler
可能还活着，继续注册会变成两个 handler 一起触发截图。

`activate` / `reactivate` / `saveBinding` / `clearBinding` 都排进同一条串行队列
（`_serialized`）：唤醒事件可能在初次 `activate()` 还在读偏好时就到达，两条路径同时
注销/注册会叠出重复 handler；`reactivate()` 自己另外还有 single-flight 和 1s 合并窗口。设置页在 macOS 上把「当前注册状态」
单独成一张卡片显示，它只反映注册调用是否成功，回答不了「系统是否真的记住了这个组合」。

macOS 睡眠/唤醒、锁屏/解锁后 Carbon 热键可能失效。托盘宿主是 `LSUIElement` 隐藏窗口
应用，`AppLifecycleState.resumed` 覆盖不到这些事件，因此在 Runner 里加了一个极小的原生桥
`SystemLifecycleBridge`（在 `macos/Runner/MainFlutterWindow.swift` 里，和 `MainFlutterWindow`
同一个文件，避免改 Xcode 工程）：

```text
NSWorkspace.didWakeNotification / screensDidWakeNotification  → macos_wake
NSWorkspace.sessionDidBecomeActiveNotification                → macos_session_active
DistributedNotificationCenter com.apple.screenIsUnlocked      → macos_unlock
    ↓ MethodChannel "hax_shot/lifecycle"
lib/features/diagnostics/app_lifecycle_bridge.dart
    ↓
lib/app.dart _recoverShortcut() → shortcutService.reactivate()
```

原生层**只发事件**，不碰快捷键注册。`reactivate()` 内部必须幂等 + single-flight：唤醒那
一刻常连着收到 wake / resume / unlock 好几个事件，直接重复 `register` 会叠出重复 handler
和泄漏的 Carbon token。默认还有一个 1s 合并窗口（`reactivateMergeWindow`），窗口内的
重复调用直接复用上次结果。

注销失败（`errorCode = SHORTCUT_UNREGISTER_FAILED`）时**必须中止本次改绑/重注册**，
不能接着注册新热键：`_unregisterInternal` 把失败原因返回给调用方，`_tryRegister` /
`reactivate()` 就此收场，`clearBinding()` 也不删偏好设置。否则旧 Carbon handler 还活着、
新绑定又注册成功，两个 handler 会一起触发截图。只有注销成功才清掉 `_registered`；失败时
保留它，下一次重试还能再注销一次。

注册成功但偏好写失败时返回 `ShortcutActivationSuccess(persisted: false)`，设置页显示「本次
已生效，但没能保存，重启后会恢复原快捷键」。**注册成功 ≠ 配置已保存**：本次可用和下次启动
可用是两件事，不能因为写偏好失败就回滚（新绑定本次确实生效了）。

`activate()` / `reactivate()` / `saveBinding()` / `clearBinding()` 共用一条串行队列
（`_serialized`），所有会改变注册状态的操作排队执行。唤醒事件撞上启动注册时不会出现
「两条路径同时注销/注册」：single-flight 只合并重复的唤醒，跨操作的互斥靠这条队列。

### 6.7 开机自启动

`MacosAutostartService` 写入 `~/Library/LaunchAgents/com.github.xiehanff.haxShot.plist`
（`RunAtLoad`）。只写文件，不调用 `launchctl bootstrap`：LaunchAgent 会在下次登录时由
launchd 自动加载，而立即 bootstrap 会在用户已经运行托盘宿主时再开一个实例。

### 6.8 macOS 特有文件

| 文件 | 职责 |
|---|---|
| `macos/Runner/MainFlutterWindow.swift` | `--capture` 浮层的窗口层级和 frame；`SystemLifecycleBridge`（唤醒/解锁 → Dart） |
| `macos/Runner/ShortcutBridge.swift` | 直接调 Carbon 注册全局快捷键，把真实 OSStatus 返回 Dart |
| `macos/Runner/CaptureDisplay.swift` | 目标显示器选择，规则必须和 Rust 保持一致 |
| `macos/Runner/AppDelegate.swift` | 关闭设置窗口不结束进程 |
| `macos/Runner/Info.plist` | `LSUIElement`（菜单栏应用，无 Dock 图标）、显示名 |
| `macos/Runner/*.entitlements` | 关闭 App Sandbox，允许加载 cargo 产出的动态库 |
| `macos/Runner/Configs/Warnings.xcconfig` | `ENABLE_USER_SCRIPT_SANDBOXING = NO` |
| `scripts/build_macos_rust.sh` | cargo 构建并复制 dylib 到 bundle |
| `lib/features/settings/macos_shortcut_service.dart` | 快捷键持久化、注册状态机、改绑事务与回滚 |
| `lib/features/diagnostics/diagnostic_log.dart` | 低频关键事件的持久化 JSON Lines 日志（轮转） |
| `lib/features/capture/capture_launcher.dart` | requestId / 起 `--capture` / ACK / 启动结果 |

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
macOS：按快捷键（Carbon 热键回调）／点托盘菜单 —— 都在宿主进程里读
Linux：GNOME 自定义快捷键直接启动 hax_shot --capture，拿不到光标屏（见上面的硬约束）
    ↓ NativeBridge.cursorDisplay() → hax_shot_cursor_display()
    ↓ HaxShot --capture --display <id>
    ├── Rust：hax_shot_capture_screen 按 <id> 抓屏
    └── Swift：CaptureDisplay.targetScreen() 调 Rust 拿同一块屏，把浮层铺上去
```

DPI：抓屏是物理像素，浮层是该显示器的逻辑尺寸，`ScreenshotLayout.fromViewport` 会自动
算出 `scale`（Retina 2x 屏上是 0.5），裁剪、标注、导出仍然按物理像素计算。混合 DPI
（内置 2x + 外接 1x）不需要特殊处理，每次截图只涉及一块屏。

**不做的**：不支持一次框选跨越两块屏。macOS 开了「显示器有独立 Space」（默认）时
WindowServer 会把窗口限制在一块屏上，跨屏选区必须为每块屏各开一个浮层窗口（Capso、
Snapzy、better-shot、flameshot 都是这个架构），属于独立的一步；详见
§17「参考仓库与许可证约束」。

#### 调试 UI 入口

托盘菜单在 debug 构建里（`lib/app.dart` 里用 `kDebugMode` 控制）多出一组 **“调试：…”**
入口，把每个界面单独列出来，不用真的截图 / 等授权就能直接打开：

```text
调试：欢迎页          FirstRunGuide（不写“已看过”标记，每次都能重看）
调试：快捷键设置      ShortcutSettingsPage
调试：权限引导        CapturePermissionGuide（不影响真实权限状态）
调试：截图浮层        HaxShot --capture（和“立即截屏”同一条路径）
调试：AI 对话窗口      HaxShot --capture --debug-ai
```

`--debug-ai` 只在 debug 构建的托盘菜单里用到：捕获进程启动后不抓屏，直接把窗口
配成 AI 面板尺寸（456×680）显示出来，用于调 AI 面板的 UI。“我已授权，重新检查”
在调试模式下只反馈当前真实授权状态。

#### 聊天窗口可以拖边缘改大小，但不会小于默认尺寸

AI 面板的默认尺寸（`_aiWindowSize = 456×680`）同时就是窗口的**最小尺寸**：
用户可以把窗口拖大，拖不回比默认更小——默认尺寸是「顶部条 + 消息列表 + 输入栏」
刚好放得下的布局，再小就没法用了。实现在 `_configureAiWindow()`：

```text
CaptureOverlayWindow.enableResizablePanel()   ← 原生：插 .resizable + 再藏一遍系统按钮
windowManager.setMinimumSize(_aiWindowSize)   ← 下限 = 默认尺寸
windowManager.setSize(_aiWindowSize)
```

两个坑：

- **必须有个原生入口**。`window_manager.setResizable(true)` 在 macOS 上是
  `styleMask.insert(.resizable)`，而这会让 AppKit 把系统自带的红黄绿按钮**重新显示
  出来**（和右上角 Flutter 自己画的 ✕ 重复）。Dart 侧没有“创建后再隐藏系统按钮”的
  API，所以只有原生层能在同一步里「插 `.resizable` + 再藏一遍按钮」——
  即 `CaptureOverlayWindow.enableResizablePanel()`。
- `setMinimumSize` 和 `setSize` 在 `window_manager` 里都是**窗口 frame**（不是 content），
  两者取同一个值，“能拖到的下限”才正好等于默认尺寸。

全屏截图浮层不受影响：`becomeOverlay()` 会把 `styleMask` 换成 `[.borderless]`，
`.resizable` 随之丢掉。

#### macOS 窗口交给 Flutter 自己管

不要 macOS 原生的红黄绿按钮（它们会压在 Flutter AppBar 自己的 ✕ 上）：

- 托盘宿主/设置窗口：`WindowOptions.windowButtonVisibility = false`（`window_manager`
  的 macOS 实现里是 `standardWindowButton(...)?.isHidden = true`）；
- 任何**改动 `styleMask` 的地方改完都要再藏一遍**系统按钮（`hideStandardWindowButtons`）：
  改 styleMask 会让 AppKit 把三个按钮重新显示出来。已经踩过一次：给聊天窗口加
  `.resizable` 之后红黄绿又冒出来了；
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
是 nil）。`RunnerTests.testPanelAppearanceUsesNativeRoundedWindow` 守着这个配置，但这个
XCTest **不在 CI 里跑**（见第 13 节）：改过窗口外观，自己跑下面这套命令。

这个测试是 **app-hosted** 的（`@testable import HaxShot`，宿主就是应用本体），所以本地跑它有三条硬要求，不然报的错跟真实问题毫无关系：

```bash
# 1. 先让 Flutter 生成 macos/Flutter/ephemeral/*.xcfilelist 和 Pods 的文件列表：直接
#    xcodebuild 会报 “Unable to load contents of file list”（flutter pub get 不够）。
#    用 --config-only 就够：只生成配置 + 跑 pod install（几秒），Debug app 交给下面的
#    xcodebuild test 自己编；先整包 `flutter build macos --debug` 会白花约两分钟。
fvm flutter build macos --config-only --debug
# 2. 必须 Debug 配置：Release 关掉了 testability，会报 “not compiled for testing”
# 3. 先退出正在运行的 HaxShot：单实例锁会让宿主 app 启动即退出，
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
atexit 收尾里，进程继续活着——窗口和托盘图标都消失了，`pgrep -x HaxShot` 还能看到。
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

- 快捷键触发时 HaxShot 通常不是前台应用；`becomeOverlay()` 必须先
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

`scripts/install-gnome-shortcut.sh` 写入 GNOME 的绑定（和 macOS 默认的 ⌥⇧Z 对齐）：

```text
gsettings binding = <Alt><Shift>z
```

旧版本装的是 `<Alt>z`。GNOME 不会替用户迁移已有的 gsettings，**升级后要重跑一次
`scripts/install-gnome-shortcut.sh`（或 `/usr/share/hax-shot/install-gnome-shortcut.sh`）**，
否则机器上还是旧的 Alt+Z；macOS 侧相反，宿主启动时会自动把历史默认值迁移掉。

快捷键不是 Flutter 内部注册的。Wayland 下普通应用不能可靠地伪造任意全局热键，所以由 GNOME 自定义快捷键执行：

```text
HaxShot --capture
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

注意：`Exec` 是普通 tray 宿主，不是 `--capture`；真正的快捷键命令由 gsettings 单独保存为 `hax_shot --capture`。`NoDisplay=false` 让 HaxShot 出现在 GNOME 应用列表中；从应用列表启动后仍只驻留托盘，不显示主窗口。

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
- 组合键转成 GNOME 格式，例如 `Alt+Shift+Z` → `<Alt><Shift>z`、`Ctrl+Shift+4` → `<Control><Shift>4`；
- 新快捷键保存到固定 schema，并确保 `custom-keybindings` 数组包含 `hax-shot` 路径；
- 删除只清空 `binding`，保留 relocatable schema，方便下一次录制直接恢复；
- 设置页关闭/隐藏后不销毁托盘宿主。

这里有一个容易踩的坑：`gsettings get` 返回的是带引号的 GVariant 文本，例如 `'<Alt><Shift>z'`，不能直接把整行当作显示文本；代码需要先去除 GVariant 引号，再转换为 `Alt+Shift+Z`。

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

当前 `CaptureToolbar` 包含取消、保存、复制、截图框选、矩形标注、箭头标注、文字标注、颜色板（红/紫/黄/绿/橙）以及截图 AI 操作：提取文字、翻译、解释、深入理解。图标统一使用 `hugeicons` 的 `strokeRounded` 风格；矩形和箭头通过拖拽绘制，文字工具通过单击创建输入框，并可拖动四角缩放字号。颜色由 CapturePage 持有并用于预览和最终 PNG。拖拽中的临时矩形仍然绘制边框，但工具栏要等 `selectionCommitted` 在 `onPanEnd` 中变为 true 后才显示。开始下一次截图选区拖拽时立即清空旧标注。

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

截图 Action 与提示词的对应关系在 `lib/features/ai/services/hax_ai_prompts.dart`，**新增动作要同时改三处**：`HaxAiAction`（enum + label）、`HaxAiPrompts.forAction()`、`HaxAiController._promptFor()`，工具条按钮另加 `CaptureToolbar.onXxx`。

聊天区的 Markdown 与代码块渲染在 `lib/features/ai/views/widgets/chat_bubble.dart`（`ChatBubble` + `CodeBlock`）。代码块头部右上角有复制按钮（复制围栏里的原始文本，不含语言标识），用 `Clipboard.setData`；「提取文字」的提示词要求模型只吐一个代码块，两者配合起来用户点一下就能拿走全文。**改代码块头部布局时不要把复制按钮挤掉**，它是这个动作唯一的出口。

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

### AI 侧栏的硬约束

- AI 必须吃 `ScreenshotExporter.renderPng()` 的最终 PNG：**不能重新截图、不能绕过标注、
  不能单独裁剪原图**；
- 新的截图 Action（提取文字/翻译/解释/深入理解）会**新建视觉会话**（清空旧会话）；同一轮里的普通
  追问只发文字，不重复上传截图；
- **AI 会话只活在当前截图进程里**，不做历史会话持久化——进程退出即丢；
- 凭据由 Host 用 `shared_preferences` 存（`hax_shot.deepseek_api_key`），
  `packages/plume_ai_chat` 不负责保存，只从 Host 的 callback 读；
- 不要再实现第二套 AI 请求 / 流式状态管理，通用对话能力全在 `packages/plume_ai_chat`
  （会话历史、HTTP/SSE、reasoning、流式预览、Stop、follow-up suggestions）；
- 网络请求最长等 60 秒，用户可以用输入框的 Stop 取消当前生成；
- 本地验证：`cd packages/plume_ai_chat && fvm flutter test`，真实请求需要在设置页配
  DeepSeek API Key。

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

源图是 `assets/icons/hax_shot_source.png`（当前 1254×1254、带透明背景，图形自带约 7%
透明留白，所以生成时直接缩放，**不要再加内边距**）。生成尺寸：16、24、32、48、64、128、
256、512px，macOS 另有 1024。

Linux 原生窗口在 `linux/runner/my_application.cc` 里 `gtk_window_set_icon_from_file()`
加载 bundle 内的 `data/hax_shot_icon.png`，同时 `gtk_window_set_icon_name(APPLICATION_ID)`
走 hicolor 图标组；CMake 安装 `share/applications/com.github.xiehanff.hax_shot.desktop` 与
`share/icons/hicolor/<size>x<size>/apps/com.github.xiehanff.hax_shot.png`。
Windows 的 ICO 与 resources **只是为将来保留**（Windows 平台未实现，见 §14），脚本照常生成。

更换图标后必须同时完成：

```bash
fvm flutter build linux --release
./scripts/install-gnome-shortcut.sh
```

正在运行的托盘进程通常已经缓存了旧图标，必须退出并重新启动 HaxShot；只替换 PNG 文件不一定会立即刷新已经显示的 AppIndicator 图标。

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
pkill -x HaxShot
```

## 13. CI 与 GitHub Release

GitHub Actions 配置位于 `.github/workflows/release.yml`，只在推送 `v*` tag 时运行（`workflow_dispatch` 用于不发布的干跑）。普通 `main` push 和 PR 只跑 `verify.yml`：Linux job 负责 analyze / Dart 测试 / Rust 检查 / Linux 构建，macOS job 负责 Dart 测试 / Rust 检查 / `flutter build macos --release`，Windows job 负责 `flutter analyze` / `cargo fmt --check` / `cargo check` / `flutter build windows --release` + bundle 完整性检查（缺文件必须 throw，不只是打印 False）。Windows job 不跑任何测试，也不上传 artifact：ZIP 打包与上传是发布流程的事（见 [`packaging.md` 的 Windows 一节](./packaging.md#windowszip-包)）。

macOS job 里的 `flutter test` **不能删**：`hotkey_binding_test`、`screen_capture_permission_test`
里有只在 macOS 上跑的用例（Carbon 键码、TCC 分支），Linux job 覆盖不到。

macOS job **不跑 `RunnerTests`（XCTest）**：它一步要 2m13s，大头是给 app-hosted 测试编一份
Debug app，日常收益不值这个时长（`flutter build macos --release` 已经在守「macOS 编得过」）。
窗口 styleMask / 圆角这类回归靠本地按「窗口圆角」那节的命令手动跑，以及跑一遍 App 来看。

本地手动跑 `RunnerTests` 有两个容易踩的坑（都实测踩过）：

- **本地要验证这一步，先 `pkill -x HaxShot`**：RunnerTests 的宿主就是 HaxShot.app，
  它的 `main()` 会抢单实例锁，抢不到直接 SIGKILL，表现成 “Test crashed with signal kill
  before starting test execution / Early unexpected exit”，看着像测试本身崩了；
- **`TEST_HOST`、产物引用、`@testable import` 的模块名都是跟着 `PRODUCT_NAME` 的**。
  改产品名（例如 `hax_shot` → `HaxShot`）时这三处都要一起改，漏一处就是
  “Could not find test host” 或 “no such module”。本地 `flutter test` 覆盖不到这一层，
  只有 `xcodebuild test` 才会暴露（CI 已经不跑这一步，改产品名时必须自己跑一次）。

`verify.yml` 的 `push` 触发器带 `paths-ignore: ['pubspec.yaml']`：发布提交只改版本号，紧接着就会被 tag 的 Release workflow 构建，不需要再跑一次 Verify。

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
version: 1.4.8+1  →  git push origin v1.4.8
```

推送 tag 后，工作流会先校验 tag 与 `pubspec.yaml` 版本一致，再分别构建 macOS arm64 DMG、
Windows x64 ZIP、Debian/Ubuntu DEB 和 Fedora RPM；四个平台 job 全部成功后才汇总上传到对应的
GitHub Release（`release.needs` 里带着 `windows`，不存在“Windows 产物还没好就把 Release 发
出去”的窗口期）。不要为普通开发 commit 创建 `v*` tag；改打包链路要先 `gh workflow run
release.yml` 干跑——Windows 这一路**还没有真实跑过一次**，首次 tag 发布前尤其需要。macOS
签名策略是“要么签+公证，要么叫 `-unsigned` 并在 Release 正文加警告”，证书和凭据 secret 见 [`packaging.md` 的发布一节](./packaging.md#发布tag版本约定与ci)。

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

Windows（清单与验收状态见 [18. Windows 平台适配](#18-windows-平台适配进行中)）：

代码层面 Phase 0–5 已落地：GDI 抓屏 + 冻结的目标元数据、多显示器浮层（`capture_window_bridge`）、
自建快捷键桥（`windows_shortcut_bridge` + `WindowsShortcutService`）、图片剪贴板
（PNG + CF_DIBV5 + CF_DIB）、HKCU Run 自启动、平台文案，窗口可见性完全由 Dart 控制。
发布链路已经接上：`release.yml` 的 `windows` job 会构建 → `scripts/package_windows_zip.ps1`
补 app-local CRT 并打 ZIP → 上传 artifact，`release` 会等它。但**这些都还没实跑**——release
干跑、真实 tag 发布、无 VS 干净机器解压运行（§51.2/§52）三项都待验，与用户验收本身一样不能
写成“已验证”；多屏 / 负坐标 / 混合 DPI / Win10 在本机缺设备，逐项状态见 18.17。
历史上 `c7a65ec` 的提交信息写过“新增 Windows 支持”，与当时实际不符。

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

如果任务是调整截图后端：保持 Mutter ScreenCast 的调用顺序，不要替换为 Screenshot Portal（原因见 §4 与 §17）。

如果任务是多显示器：先读 [6.9 多显示器](#69-多显示器)。macOS 的选屏规则（`--display` →
光标 → 主屏）只在 `rust/src/macos.rs` 的 `resolve_target_display()` 里实现一遍，Swift 通过
`dlopen` 调 `hax_shot_target_display` 取 `CGDirectDisplayID`；改规则只改 Rust，不要在
`macos/Runner/CaptureDisplay.swift` 里重抄一遍候选顺序。Linux 需要多窗口架构，不能只改抓屏。
要支持跨屏框选，必须改成“每块屏一个浮层窗口 + 跨窗口选区同步”，不要试图用一个窗口去跨屏。

如果任务涉及托盘/菜单栏图标：macOS 菜单栏用**应用图标本身**（`assets/icons/hax_shot.png`，
`setIcon` 不传 `isTemplate`），Linux 同一张 PNG，Windows 用 `hax_shot.ico`。有人试过改成单色
template 方案（`isTemplate: true` + 单色遮罩图），被要求改回：菜单栏图标必须和应用图标一致，
不要以“深色菜单栏看不清”为理由再引入第二张图标。见 §11。

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

## 16. 标注交互边界

一次截图里有**两个不同的矩形**，别混：

1. **截图选区**：第一次拖拽决定最终保存/复制的范围；
2. **标注范围**：点矩形/箭头工具后，在选区内部再拖拽。

第二次拖拽**不改变截图选区**，只新增标注，且标注的起点终点被限制在选区内。工具条上
「框选截图区域」和「标注矩形」是两个按钮，只有前者会重新开一次截图选区。

| 工具 | 交互 | 约束 |
| --- | --- | --- |
| 矩形 | 选颜色 → 在选区内拖拽 → 松开提交 | 用 `Rect.fromPoints`，任意方向拖都有效 |
| 箭头 | 选颜色 → 按下拖动 → 松开提交 | 起点是箭尾、终点是尖端，拖动距离决定长度；线段 + 两条开放式翼 |
| 文字 | 在选区内单击 → 输入 → 四角缩放 / 顶部抓手移动 | 四角缩放按比例同步字号；抓手上的关闭按钮删除当前文字；**编辑态（边框/控制点/抓手/关闭按钮）不写进最终 PNG**；点已有文字重新编辑，点别处先提交当前文字 |

这些交互**没有自动化测试**，只能在真机上手动验：截图 → 依次点矩形/箭头/文字在选区内
操作 → 点复制或保存 → 检查导出的 PNG 里只有标注、没有编辑态控件。

## 17. 参考仓库与许可证约束

参考仓库只克隆到 `references/` 本地阅读，**不随项目发布、也不复制代码**；原来的 4 份
源码阅读报告（reticle / snapshotkit / screenshot / snapclip）已删除，需要时看 git 历史。

| 参考 | 在 HaxShot 里怎么用 | 许可约束 |
| --- | --- | --- |
| Reticle | 冻结画面、框选、输出流水线、贴图的产品体验 | Apache-2.0 **+ Commons Clause**：不能按普通 Apache 复用代码 |
| SnapShotKit | point/pixel 坐标规范、统一 flatten、PNG/剪贴板输出 | MIT：复用需保留版权和许可证文本 |
| Screenshot | 最小主链路、单帧捕获、排除 overlay、Save/Copy | README 声称 MIT 但仓库缺 LICENSE 正文：上游确认前不复制 |
| snapclip | GNOME Wayland 的 Mutter ScreenCast + PipeWire 单帧捕获 | 只参考调用顺序 |

最要紧的一条：**保持 Mutter ScreenCast 的调用顺序，不要替换成 Screenshot Portal**
（Portal 会播放快门声/闪光，产品不接受，见 §4）。

## 18. Windows 平台适配（进行中）

Windows 适配按 Phase 推进，本节记录**已经实测过的事实**，以及 3 个平台共享文件上不允许
破坏的边界。每个 Phase 的产物与验收都在这节里追加，不另建文档。

### 18.1 本机工具链（2026-09-19 实测）

| 组件 | 版本 / 路径 |
| --- | --- |
| OS | Windows 11 `10.0.22631`（x64） |
| Flutter | 3.44.8 stable，由 fvm 管理（仓库 `.fvmrc`）；本机命令一律 `fvm flutter ...` |
| Dart | 3.12.2 |
| Rust | rustc 1.97.1 / cargo 1.97.1，`C:\Users\chink\.cargo\bin\cargo.exe` 在 PATH 里 |
| Visual Studio | VS2022 Community（`C:\Program Files\Microsoft Visual Studio\2022\Community`，含 `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`） |
| Windows SDK | 10.0.22621.0、10.0.26100.0 |

实物条件：单显示器 `\\.\DISPLAY1`，工作区原点 (0,0)（没有左侧副屏 → 负坐标测不了）。
本机**没有副屏、也不是混合 DPI**，所以「副屏在主屏左边（负坐标）」「两块屏缩放不同」
这两类场景本机测不了，只能标“待验”。

**分辨率必须用 PerMonitorV2 宿主量（Phase 3 更正）**：

```text
PerMonitorV2 进程（hax_shot.exe）：rcMonitor=(0,0,3840,2160)，GetDpiForMonitor=144（150% 缩放）
非 DPI 感知宿主（Phase 2 的 dart run 脚本、默认 powershell.exe）：2560x1440 + 96 dpi（虚拟化后）
```

这两个数是同一台机器的同一个屏幕：`3840/1.5 = 2560`、`2160/1.5 = 1440`，工作区高度差
`48` 物理像素也正好是 150% 下 32 逻辑像素的任务栏。所以 [18.13](#1813-phase-2-本机实测结论2026-09-19)
里“2560x1440 @100%”的读数是**虚拟化视角**，不是物理分辨率。以后量显示器、量窗口 rect、
截屏都必须用 PerMonitorV2 宿主（PowerShell 先 `SetProcessDpiAwarenessContext(-4)`），
否则拿到的全是缩放后的坐标。

`windows/runner/runner.exe.manifest` 已声明 `PerMonitorV2`，不需要改 DPI awareness。

### 18.2 基线构建结论（Phase 0）

`fvm flutter build windows --debug` 退出码 0（69.7s），产物在 `build/windows/x64/runner/Debug/`：

```text
hax_shot.exe  flutter_windows.dll
插件 DLL：tray_manager / window_manager / hotkey_manager_windows /
         screen_retriever_windows / super_native_extensions / desktop_drop /
         file_selector_windows / url_launcher_windows / irondash_engine_context
```

**唯独没有 `hax_shot_native.dll`**：`windows/CMakeLists.txt` 从来没接过 cargo。
这就是 Phase 1 要补的第一件事（见 18.3）。插件 DLL 都在，说明 Windows 侧 C++ 工具链没问题。

Phase 1 收尾的 `fvm flutter build windows --release` 退出码 0，`build/windows/x64/runner/Release/` 里
能看到 `hax_shot.exe`、`hax_shot_native.dll`、`flutter_windows.dll`、全部插件 DLL 与
`data/app.so` + `data/icudtl.dat` + `data/flutter_assets/`。“构建成功”不等于 DLL 能加载，
真正的判定标准见 18.7。

### 18.3 Phase 1 的 Windows 构建规则（踩过的坑）

`windows/CMakeLists.txt` 里新增了唯一的 Rust 规则（对应 `linux/CMakeLists.txt` 的那段，
但**不要照抄它的环境假设**）：

- `RUST_TARGET_DIR` 显式写成 `rust/target`，并给 cargo 传 `--target-dir`；不依赖外部环境变量，
  也不给整个构建设置全局 `CARGO_TARGET_DIR`（`super_native_extensions` 走 cargokit 自己管
  构建目录，抢同一目录会互相污染）；
- MVP 统一用 `--release`：Debug / Profile / Release 三种 Flutter 配置都装同一份 release DLL，
  bundle 里只有一个稳定产物；
- **不传 `--target`**：本机与 CI 的 host 就是 `x86_64-pc-windows-msvc`，产物在 `<target-dir>/release/`。
  以后一旦加 `--target <triple>`，cargo 命令行与 `RUST_LIBRARY` 路径必须同时变成
  `<target-dir>/<triple>/release/`，改一处会静默复制旧 DLL；
- 安装用 `install(FILES ... DESTINATION "${CMAKE_INSTALL_PREFIX}")`，而且这段**必须写在文件末尾的
  安装区之后**：`CMAKE_INSTALL_PREFIX` 在那个文件里被强制成 `$<TARGET_FILE_DIR:hax_shot>`
  （= 当前配置的 bundle），放在前面会装到 CMake 的默认前缀去；
- `runner` 目标加 `add_dependencies(${BINARY_NAME} hax_shot_native)`（CMake 会生成
  `hax_shot_native.vcxproj` 的 ProjectReference），保证 DLL 先于打包；
- `find_program(CARGO_EXECUTABLE ... HINTS "$ENV{CARGO_HOME}/bin" "$ENV{USERPROFILE}/.cargo/bin")`：
  不把 `HOME` 当 Windows 前提（本机 `HOME` 恰好存在，但不能假定）；
- 依赖追踪的 `DEPENDS` 含 `rust/src/*`、`Cargo.toml`、`Cargo.lock`，`COMMAND` 用独立参数 + `VERBATIM`。

### 18.4 Runner 源文件必须是 UTF-8（C4819）

`windows/runner/*.cpp` 里加中文注释后，MSVC 报
`warning C4819: 该文件包含不能在当前代码页(936)中表示的字符`，而 `apply_standard_settings()`
开了 `/WX`，于是直接变成编译错误、`flutter build windows` 失败。修法不是删注释，而是在
`windows/runner/CMakeLists.txt` 里给 runner 目标加
`target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")`。

**不要**把 `/utf-8` 放进 `windows/CMakeLists.txt` 的 `apply_standard_settings()`：那个函数
插件目标也在用，编译选项会外溢到 vendored 插件的 C++ 源码。以后新增
`capture_window_bridge.cpp` / `windows_shortcut_bridge.cpp` 时注释照写中文，选项已经就位。

`windows/runner/CMakeLists.txt` 用的是**显式源文件列表**（不是 GLOB）：新源文件必须加进
`add_executable()`，否则就是“代码写了但没编进去”。

### 18.5 窗口可见性：只有 Dart 是 owner

`windows/runner/flutter_window.cpp` **不再**注册 `SetNextFrameCallback(Show)`、也不调
`ForceRedraw()`：Win32 模板用 `WS_OVERLAPPEDWINDOW`（不带 `WS_VISIBLE`）创建窗口，本来就不可见，
只要不主动 `Show()`，宿主与 `--capture` 子进程都不会先闪一帧 1280x720 的默认窗口。
显示/隐藏一律走 Dart 的 `window_manager`（`lib/features/window/window_visibility.dart`），
`main.dart` 在 `waitUntilReadyToShow` 之后立即 `hide()`。

不要改成“不创建窗口”：`main.cpp` 的窗口创建与消息循环保持现状，窗口隐藏着也可以
接收 `window_manager` 的消息；托盘宿主的圆角/透明底色（`RoundedWindow` + `ClipRRect`）也
依赖窗口已经存在。

### 18.6 托盘左右键：Windows 必须自己弹菜单

本地 vendored 的 `packages/tray_manager/windows/tray_manager_plugin.cpp`（`pubspec.yaml` 的
`dependency_overrides` 指向它）在 `WM_LBUTTONUP` / `WM_RBUTTONUP` 上**只 invoke Dart 回调**，
不会自己弹菜单；菜单要另调 `PopUpContextMenu` → `TrackPopupMenu`。所以 `lib/app.dart` 的
`_popUpTrayMenu()` 对 Linux `return`（AppIndicator 自己弹，重复调用会弹两次），
macOS 与 Windows 都走 `trayManager.popUpContextMenu()`。

### 18.7 DLL 加载：exe 旁绝对路径 + 分层诊断

`lib/native/native_bridge.dart` 的候选顺序：

```text
macOS  → Contents/Frameworks/hax_shot_native.dylib → exe 旁 → 裸名
Windows→ <exe 目录>\hax_shot_native.dll（绝对路径优先）→ 裸名
Linux  → <exe 目录>/lib/libhax_shot_native.so → exe 旁 → 裸名
```

exe 目录用 `File(Platform.resolvedExecutable).parent.path`，与 `DartProject(L"data")` 解析
`data/` 的锚点一致。失败时抛出的错误**汇总所有候选**（每条候选路径 + 各自真实错误），
分三层：候选文件不存在 / 文件在但加载失败（缺依赖 DLL，带系统错误原文）/ 加载成功但
符号缺失（带成功的 DLL 路径与缺失的符号名）。

Windows 上 Rust DLL 是**动态加载**的（`DynamicLibrary.open`），不是静态导入：静态导入一旦
失败进程根本起不来，Dart 侧的分层诊断就没机会跑。验 DLL 也不要看“托盘出来了”——
`NativeBridge.instance` 是惰性 static，宿主启动不一定碰它；真实触发点是
`_displayArguments()`（读光标显示器）与 `--capture` 的抓屏路径。

### 18.8 Phase 1 结束时仍未实现的 Windows 分支

- `lib/features/settings/shortcut_service.dart` 的平台选择只有 macOS 与“其它（= GNOME）”：
  Windows 上会去跑 `gsettings`，于是启动链的 `welcome_init_failed`（`ProcessException`），
  **首次启动的欢迎页不会弹**。托盘菜单、托盘图标不受影响（`tray_init_success`）。真正的
  修法是 Phase 4 的显式三平台选择（Windows 走 RegisterHotKey + 原生桥）；
- Rust 侧只剩剪贴板还是 placeholder（`copy_png_impl` 返回
  “Windows clipboard backend is not implemented yet”，Phase 5 实现）。抓屏、选屏与
  目标元数据已在 Phase 2 实现（见 18.9–18.12）。

### 18.9 目标显示器：选屏规则与 display id（Phase 2）

规则在 `rust/src/windows.rs` 实现一次，macOS / Windows **共用同一套形状**
（macOS 是 `resolve_target_display`，Windows 是 `resolve_target_monitor`）：

```text
requested（--display <id>）非 0 且仍存在 → 用它
否则                                   → 光标所在显示器
再不行                                 → 主显示器
```

- `0` 的含义是“未指定”，**不是**“主屏”；`requested` 无效是正常分支（用户可能刚拔掉
  副屏），既不报错也不造一个假 id，只是退回下一候选；
- `--display <id>` 由 Rust 自己从 `std::env::args()` 解析（`lib.rs` 的
  `display_id_from_arguments`，macOS / Windows 共用）；Dart 只负责把托盘宿主那一刻的
  `cursorDisplay()` 传下去（`lib/app.dart` 的 `_displayArguments()`）。

**display id 是 FNV-1a 32 位**，输入是 `MONITORINFOEXW.szDevice`（形如 `\\.\DISPLAY1`）：

```text
offset_basis = 0x811C9DC5, prime = 0x01000193
逐 UTF-16 code unit 取低字节（szDevice 本身是 ASCII）
每字节：hash ^= byte; hash = hash.wrapping_mul(prime)
遇到终止 NUL 停止（不含 NUL），不做大小写转换
```

本机实测：`\\.\DISPLAY1` → `3229624234`（`0xC08027AA`）。策略：

- `hash == 0`：保留值冲突，这块屏**无法寻址**，记诊断且不选它；
- 两块屏 hash 相同：返回 `HASH_COLLISION(4)`，不允许“选第一个假装成功”；
- 这个 id 只是**当前拓扑内**的标识，不承诺重启 / 重插后还代表同一台物理显示器。

**只由 Rust 实现一次**：C++ / Dart 不允许调 `EnumDisplayMonitors` / `MonitorFromPoint` /
`GetMonitorInfoW`，不允许自己写一份 hash，也不允许“拿不到元数据就自己猜个主屏”。

### 18.10 冻结语义与元数据 ABI（Phase 2）

共用同一个 resolver **不等于**共用同一个结果：`requested` 缺失 / 失效时，两次调用之间
鼠标移动或热插拔完全可能“抓 A 摆 B”。所以 Windows 是“一次解析、两处消费”：

```text
capture_screen_impl：resolve 一次 → 抓帧 → 写 PNG → 成功才把
  {generation, display_id, rect, dpi} 写进进程内的冻结槽
浮层摆位：只读 hax_shot_last_capture_target()，不重新枚举、不重新读鼠标
```

`generation` 每成功一次抓屏 +1（u64）。冻结槽是
`static CAPTURE_STATE: OnceLock<Mutex<CaptureState>>`：抓屏跑在 worker isolate 的线程上，
读元数据在别的线程，所以不能用 `Cell` / `Rc`（宿主进程内不跨进程、不持久化）。

两个 Windows 专用导出（`#[cfg(target_os = "windows")]`，共用 `#[repr(C)]
HaxShotTargetMonitor`，56 字节）：

```text
hax_shot_target_monitor(requested: u32, out: *mut HaxShotTargetMonitor) -> i32   只查询，不抓屏；诊断/预检用
hax_shot_last_capture_target(out: *mut HaxShotTargetMonitor) -> i32             读冻结的本次目标；摆浮层只能用这个
```

错误码（`error_code` 与返回值同一套，便于 Dart / C++ 两边都读）：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 0 | ok | 成功；`valid=1` |
| 1 | NO_TARGET | requested / cursor / primary 都拿不到；抓屏前读冻结槽也是它 |
| 2 | ENUM_FAILED | `EnumDisplayMonitors` 失败（带真实 Win32 错误码） |
| 3 | DEVICE_NAME_FAILED | `GetMonitorInfoW` 失败（带真实 Win32 错误码） |
| 4 | HASH_COLLISION | 两块屏 id 相同，或 hash 落到保留值 0 |
| 5 | TARGET_STALE | 冻结的 `display_id` 已经不在拓扑里，或它的 `rcMonitor` 变了 |
| 6 | INVALID_ARGUMENT | `out` 指针为空 |

约定：

- 失败时**仍然**往 `out` 写一份 `valid=0` + `error_code=<code>` 的结构体（其它字段清零），
  调用方可以统一读；可读文本走现有的 `hax_shot_last_error`，不往结构体里塞字符串；
- `reserved` 是抓屏诊断位域（摆位不看它）：bit 0 = 疑似全黑，bit 8..=15 = 采样平均亮度；
  `hax_shot_target_monitor`（只查询）始终填 0；
- `TARGET_STALE` 是 §8.9 的取消信号：目标消失 / 尺寸变化时本次截图作废，**不**拿旧图
  套新屏、不退回主屏。校验只做“这块屏还在不在、rect 变没变”的只读比对，不重新解析
  fallback；DPI 变化不在这一步判（Phase 3 摆位时比对 dpi）。

### 18.11 GDI 抓屏：资源契约、尺寸与错误码（Phase 2）

`rust/src/windows.rs` 的 `capture_frame` 按下面顺序走，资源全用 RAII guard 包住
（`ScreenDc` / `MemoryDc` / `Bitmap`，Drop 顺序 = 位图 → memory DC → screen DC）：

```text
screen_dc = GetDC(NULL)
mem_dc    = CreateCompatibleDC(screen_dc)
bitmap    = CreateCompatibleBitmap(screen_dc, w, h)   ← 必须用 screen DC
SelectObject(mem_dc, bitmap)
BitBlt(mem_dc, 0, 0, w, h, screen_dc, left, top, SRCCOPY | CAPTUREBLT)
SelectObject(mem_dc, old)                             ← ★ 先选回旧对象，再 GetDIBits
GetDIBits(screen_dc, bitmap, 0, h, buffer, &bmi, DIB_RGB_COLORS)
```

写的时候不能踩的坑：

- `CreateCompatibleBitmap` 用刚建的 memory DC 会得到 1×1 单色位图；
- `GetDIBits` 时位图**不能**还被任何 DC 选中（所以先选回旧对象）；`SelectObject` 的返回值必须
  检查——只有成功才把 `Bitmap.selected_in` 清掉，失败就中止 `GetDIBits` 并返回带操作名的错误；
  `Bitmap::drop` 只在解除选择**成功**后才 `DeleteObject`（失败宁可漏一个 GDI 对象，也不删一个
  仍被 DC 选中的位图，否则 DC 会持有悬空句柄）；
- `left/top` 用 `rcMonitor` 的物理坐标，允许为负，**不** clamp、也不裁成“主屏起点为 0”；
- 行方向用 top-down（`biHeight = -height`），Flutter 侧不再翻转；验收看的是“图不是上下
  颠倒的”：拿屏幕 DC 的 `GetPixel(0,0)` / `GetPixel(0,h-1)` 和 PNG 同位置比，本机 4/4
  命中、垂直翻转后 0/4 命中；
- alpha 一律写 255，绝不把未初始化的 alpha 写进 PNG（DIB 是 BGRA，转换时顺手改);
- `GetDIBits` 的返回值是**扫描行数**：`!= height` 就是失败，不按“缓冲区前 N 行有数据”凑合；
  同时确认系统没有默默改掉我们自己填的 `biSize / biWidth / biHeight / biBitCount /
  biCompression`；
- 任何 Win32 调用之前先校验：`0 < w,h <= 32768`、`stride = w * 4`、`stride * h` 都用
  `checked_mul`；超过上限直接失败，不静默截断。单轴上限挡不住极端组合（32768×32768 的
  32bpp 像素缓冲区是 4 GiB），所以再按总量封顶：`MAX_FRAME_PIXELS = 64M`、
  `MAX_FRAME_BYTES = 256 MiB`（正常 8K 7680×4320 只有 ≈126 MiB，不受影响）；
- `rcMonitor` 的宽高（`right - left` / `bottom - top`）用 `i64` 相减再 `i32::try_from`
  （`checked_axis`），选屏 / metadata / 冻结共用 `MonitorEntry::size()` 这一份结果：
  `i32` 直接相减在 debug 会 panic、release 会 wrap；
- PNG 写盘失败要删掉半成品（0 字节或半截 PNG），删失败不能掩盖主错误。

错误按每个 API 自己的契约取（不要一律 `GetLastError`）：

| API | 失败时取什么 |
| --- | --- |
| `EnumDisplayMonitors` / `GetMonitorInfoW` / `GetCursorPos` / `BitBlt` | 文档承诺 set last error，失败后**立刻**读 |
| `GetDC` / `CreateCompatibleDC` / `CreateCompatibleBitmap` / `SelectObject` | 只承诺返回空句柄，不说 set last error → 记操作名 + 自有错误码（`SelectObject` 失败时位图可能仍在 DC 里，必须中止后续步骤） |
| `GetDIBits` | 返回值是扫描行数 → 记返回值与期望高度，不声称是系统错误 |
| `GetDpiForMonitor` | `HRESULT` → 失败就把 dpi 填 0 |

错误信息格式（和现有三个平台一致，保留操作名 + 真实 native code）：

```text
backend=gdi requested=3229624234 source=cursor display_id=3229624234 rect=(0,0,2560,1440)
  size=2560x1440 stride=10240 dpi=96 BitBlt failed at (0,0,2560,1440): Win32 error 5
GetDIBits copied 0 scan lines, expected 1440 (bitmap 2560x1440)
```

`SRCCOPY | CAPTUREBLT` 只是“尽量包括 layered window”，**不是**对硬件 overlay / 鼠标 /
色彩管理的承诺：本版不合成鼠标指针，也不做 HDR / 受保护内容（§66）。

### 18.12 全黑只告警，不判错（Phase 2）

抓完图后按步长采样（最多 4096 个像素）算平均亮度，写进冻结元数据 `reserved` 的
bit 8..=15；“平均亮度 ≤ 2 且最亮像素 ≤ 16”时置 bit 0。日志里能看到：

```text
capture_target_resolved  backend=gdi display_id=… rect=(…) size=2560x1440 dpi=96 generation=1
capture_suspected_blank  level=warning 疑似全黑（仅告警）：mean_luma=… size=… display_id=…
```

`capture_target_resolved` 由 `lib/features/capture/capture_page.dart` 抓屏成功后调
`NativeBridge.lastCaptureTarget()` 记录（同一份冻结数据，不是重新枚举），失败也不影响
已经成功的抓屏。

黑桌面 / 全黑壁纸 / 过场动画都可能合法地产生“全黑”，所以**不允许**据此自动判失败、
自动重截，也不把截图内容写进日志。真的出现**可复现**黑图时：先拿日志里的 backend /
尺寸 / API 结果 / 采样值，再决定是否降级到 `PrintWindow` / WGC / DXGI（Phase 2 不预先实现）。

### 18.13 Phase 2 本机实测结论（2026-09-19）

单屏 2560x1440 @100%（96 dpi）上，仓库外的一次性 `dart:ffi` 脚本直接调 DLL：

```text
cursor_display()                3229624234（两次一致、非 0）
target_monitor(0)               ok，display_id 与 cursor_display() 相同
                                 rect (0,0,2560,1440)，width/height 2560x1440，dpi 96
target_monitor(0xDEADBEEF)      ok，退回光标所在显示器（requested 无效是正常分支）
last_capture_target() 抓屏前    NO_TARGET(1)，valid=0
capture_screen()                0，PNG 路径存在，1.4MB，IHDR 2560x1440 RGBA8
last_capture_target() 抓屏后    ok，generation=1，display_id/rect 与抓屏前解析一致
像素抽查                        64 个样本 alpha 全 255、非纯黑 100%、均值 luma ≈105
角点交叉验证                    屏幕 GetPixel 与 PNG 同位置 4/4 命中（方向 + 通道序正确）
```

**本机测不了、只能标“待验”**：副屏 / 多屏（含负坐标的左副屏）、混合 DPI、Windows 10、
HDR / 受保护内容、独占全屏。多屏相关的代码路径（`source=requested` 选中副屏、
`TARGET_STALE`）在本机无法触发。

注：这份读数（2560x1440 / 96 dpi）是 **DPI 虚拟化**后的坐标，物理值是 3840x2160 / 144 dpi，
见 18.1 的更正。

### 18.14 Phase 3：多显示器浮层与窗口所有权

#### 谁拥有窗口

`windows/runner/capture_window_bridge.{h,cpp}` 是 overlay 态窗口属性的**唯一 owner**
（channel 名沿用 `hax_shot/capture_window`）。所有权按状态切：

| 状态 | style / rect / topmost | 非客户区消息 | 尺寸、层级、可缩放 |
| --- | --- | --- | --- |
| 普通面板（引导页 / 失败面板 / AI 面板 / 设置页） | `window_manager` | 插件（hidden titlebar 分支） | `window_manager` |
| overlay（冻结画面浮层） | `CaptureWindowBridge` | bridge（只拦 `WM_NCCALCSIZE`） | bridge |

- `becomeOverlay` **只配置、不显示**：切 `WS_POPUP`（保留 `WS_CLIPCHILDREN/WS_CLIPSIBLINGS`）、
  按**冻结元数据**的 rcMonitor `SetWindowPos(HWND_TOPMOST, …)`，不带 `SWP_SHOWWINDOW`；
  窗口保持隐藏，由 Dart 的 `showWindow()` 唯一显示。窗口当前可见时先 `SW_HIDE` 再配置；
- `exitOverlay` 幂等：不在 overlay 态直接成功；恢复顺序 style/exStyle → rect → topmost
  （一次 `SetWindowPos` + `SWP_FRAMECHANGED`），然后 `GetWindowLongPtr`/`GetWindowRect`
  回读校验，失败重试一次，仍失败就报错；
- 摆位 rect 只来自 Rust：`hax_shot_last_capture_target()` 用 exe 目录绝对路径
  `LoadLibraryExW` + `GetProcAddress` 动态解析。C++ 里没有 `EnumDisplayMonitors` /
  `GetMonitorInfoW` / hash。

#### 消息路由（顺序不能换）

`FlutterWindow::MessageHandler`：**bridge 钩子 → `HandleTopLevelWindowProc`（Flutter + 插件）
→ `Win32Window::MessageHandler` → bridge 的 DPI 收尾**。

- bridge 必须在插件**之前**：`window_manager` 的顶层消息代理处理 `WM_NCCALCSIZE` 时会在
  hidden titlebar 分支把客户区左右/底各缩 8 像素并 `return 0`，放到它后面就永远轮不到 bridge；
- overlay 态的 `WM_NCCALCSIZE` 直接把 `rgrc[0]` 设成目标 rcMonitor 的屏幕坐标并 `return 0`
  （不缩 8 像素、不加 Win10 顶部那 1 像素）；恢复快照期间这个拦截会临时关掉，
  否则面板态拿不到插件该给的 inset；
- `WM_DPICHANGED` 不吞：先让插件与 `Win32Window` 用 OS 建议的 rect 走完（Flutter 才会拿到
  新 DPR），收尾时 bridge 再把窗口钉回冻结元数据的 rcMonitor。重钉 `SetWindowPos` 会检查返回值
  与 Win32 错误、最多重试 3 次（间隔 20ms）；仍失败就把物理契约标成失效并主动推
  `overlayRepinFailed` 给 Dart（见下面的事件表），**不再**只留在 debugger 输出里。若此时冻结
  元数据已经过期，就保持原 overlay rect、把错误码一起放进事件 payload（不撕掉浮层）；
- `WM_SIZE` 不拦，继续走 `Win32Window` 把 Flutter child 铺满客户区。

#### channel 协议（Windows）

```json
// Dart → native
{"displayId": 3229624234, "generation": 1}   // 0 = 未指定 / 不校验
// native → Dart（成功）
{"displayId": …, "generation": …, "clientRect": {"left":0,"top":0,"right":3840,"bottom":2160}, "dpi": 144}
// 失败：FlutterError(code, message)，code 用 18.10 的错误码（0..7）
// native → Dart 事件（WM_DPICHANGED 重钉失败，物理契约失效）
{"win32Error": 0, "message": "重新钉回目标 rcMonitor 失败：…", "targetErrorCode": 0,
 "overlayRect": {"left":0,"top":0,"right":3840,"bottom":2160}}
```

- `overlayRepinFailed` 是桥主动 `InvokeMethod` 的事件（与快捷键桥的 `triggered` 同一约定）。
  Dart 侧 `capture_overlay_window.dart` 解析成 `CaptureOverlayRepinFailure`，`capture_page.dart`
  写 `overlay_repin_failed` / `OVERLAY_REPIN_FAILED` 并进失败面板；契约失效后
  `becomeOverlay` 的幂等分支会返回 `TARGET_STALE(5)`，不再返回一个“看着成功”的摆位结果；

- `displayId`/`generation` 用 `TryGetLongValue()` 取：runner 带 `_HAS_EXCEPTIONS=0`，
  `std::get<int>` 类型不匹配时不是抛异常而直接终止进程；
- 一致性校验：Dart 带的 `displayId`（`--display` 的值）与冻结的 display_id 不一致、或
  `generation` 对不上 → `TARGET_STALE(5)`，**不**换目标、**不**退回主屏；
- 摆位后 bridge 自己回读断言（不满足就报错并按快照回滚）：`GetWindowRect == rcMonitor`、
  `GetClientRect == rcMonitor 尺寸`、`ClientToScreen(0,0) == rcMonitor 原点`。
- 桥保留同名的 `enableResizablePanel`（no-op）：Windows 的普通面板本来就带 `WS_THICKFRAME`，
  可缩放仍由 `window_manager` 负责，退出 overlay 后 bridge 不再碰窗口。

#### Dart 侧

- `capture_overlay_window.dart`：`_enabled` = macOS | Windows；Windows 的 `becomeOverlay`
  走桥并把返回值解析成 `CaptureOverlayPlacement`，失败抛 `CaptureOverlayException`
  （带 native code），**不 fallback** 到 `setFullScreen(true)`（那会造成“抓 A 屏、浮层全屏在
  主屏”的假成功）。macOS 的 fallback 语义与 Linux 的 `setFullScreen` 不动；
- `capture_process_lifecycle.dart`：`becomeOverlay(targetDisplay, generation) → showWindow()
  → focus()`（focus 失败只记日志、不阻断），返回值交给页面记契约;
- `capture_page.dart`：`CaptureOverlayException` 进失败面板（可重试 / 可关闭），
  并写 `overlay_become_failed`；失败不释放捕获锁（锁只在进程真的退出时释放）；
- `lib/app.dart`：Windows 跳过 `setFullScreen(false)` / `setAlwaysOnTop(false)` /
  `unmaximize()` 三个写入：桥已经在 `exitOverlay` 里按快照恢复过 style / rect / topmost，
  再跑一遍会二次改状态（`setAlwaysOnTop(false)` 无条件清 `WS_EX_TOPMOST`、`unmaximize()` 会动
  窗口 rect）；后续 `_configureAiWindow()` 会按 AI 面板尺寸重新 `setSize/center`；
- `window_visibility.dart`：只有 macOS 调 `setOpacity(1)`——Windows 的 `setOpacity` 会无条件
  给窗口加 `WS_EX_LAYERED`，浮层不能是分层窗口。

#### 事件与契约数据

```text
capture_ready        图像已解码、可以交互（含义不变）
overlay_ready        becomeOverlay + showWindow + focus 都完成；同一条日志里有
                     client=… rcMonitor=… png=… dpi=… viewport=… logical=… dpr=…
                     layout_scale=… contract_ok=…（false 时是 warning）
overlay_become_failed level=error + error_code=OVERLAY_BECOME_FAILED + message 里的 native code
overlay_repin_failed  level=error + error_code=OVERLAY_REPIN_FAILED：WM_DPICHANGED 后重钉失败，
                     message 里有 win32_error 与目标 rect；页面进失败面板（不 fallback、不释放锁）
```

`contract_ok=false` 时先查 bridge（`GetClientRect` / `WM_NCCALCSIZE` / DPI），**不要**给选区
加补偿边距。`capture_page` 的 `_ackRequest` 现在**无条件**写日志（只在有 `--request-id` 时
才写请求文件），这样手动 `hax_shot.exe --capture` 也不会丢掉失败原因。

#### 本机实测（单屏 3840x2160 @150%）

一次性 PowerShell 脚本（Win32 P/Invoke，**不进仓库**）直接起
`hax_shot.exe --capture --display 3229624234`：

```text
PowerShell 先 SetProcessDpiAwarenessContext(-4)，否则读到的是虚拟化坐标
cursor_display = 3229624234；target_monitor = (0,0,3840,2160) 3840x2160 dpi=144
overlay 可见用时 ≈ 1s
hwnd=0x2D04CA class=FLUTTER_RUNNER_WIN32_WINDOW window=(0,0,3840,2160)
  client=(0,0,3840,2160) clientOrigin=(0,0) style=0x96000000 exstyle=0x00000008
  → window == client == rcMonitor（偏移 0,0、尺寸差 0,0）；WS_POPUP + WS_EX_TOPMOST；
    没有 WS_EX_LAYERED；没有 1280x720 默认窗口
进程内日志 overlay_ready：client=(0,0,3840,2160) rcMonitor=(0,0,3840,2160) png=3840x2160
  dpi=144 viewport=3840x2160 logical=2560x1440 dpr=1.5 layout_scale=0.6667 contract_ok=true
结束后：可见窗口 0、临时 PNG 0、捕获锁 free、交接 ready 0
```

失败路径也自动验过一次：`--display 123456789`（合法 u32、但不在拓扑里 → Rust 按规则退回
光标屏）→ Dart 侧 display_id 对不上 → 桥返回 `TARGET_STALE(5)` → 出现 560x480 的小窗口
失败面板（不是全屏、不是 topmost、不是 `WS_POPUP`），日志写
`overlay_become_failed` / `OVERLAY_BECOME_FAILED` / `native code=5`。

本机测不了（**待验**）：副屏（含左侧负坐标副屏）、混合 DPI、跨屏摆浮层、拔屏触发的
`TARGET_STALE`、`WM_DPICHANGED` 的真实触发，以及 AI 面板路径里的 `exitOverlay` 恢复。

### 18.15 Phase 5：剪贴板 / 自启动 / 保存路径 / 托盘菜单

#### Windows 剪贴板后端（`rust/src/windows.rs`）

- **owner HWND 不是可选项**：`OpenClipboard(NULL)` 之后 `EmptyClipboard` 会把 owner 置成
  NULL，随后的 `SetClipboardData` 必然失败。这里由 Rust 自己起一个专职线程
  （`hax-shot-clipboard`），用**系统类 `STATIC`** 建一个 0×0、`WS_POPUP`、`WS_EX_TOOLWINDOW`
  的隐藏窗口当 owner：线程活着窗口就活着（进程生命周期内不销毁），窗口只负责当 owner，
  不处理业务消息；`recv_timeout(20ms)` + `PeekMessageW`/`DispatchMessageW` 的消息泵保证
  创建它的线程一直在处理消息。用系统类是为了免掉 `RegisterClassW` 与模块句柄；
- **即时数据，不用 delayed rendering**：内存交给系统后与本进程是否存活无关——抓屏子进程
  复制完立刻硬退出也必须能粘。实测确认退出后仍可读回；
- **三种格式一起写，顺序是 PNG → CF_DIBV5 → CF_DIB**：注册格式 `PNG` 直接保存调用方的
  原始 PNG 字节（alpha 也原样保留）；CF_DIBV5 是 124 字节 `BITMAPV5HEADER` + `BI_RGB`；
  CF_DIB 是 40 字节 `BITMAPINFOHEADER` + `BI_RGB`。两种 DIB 都是 **top-down（负
  `biHeight`）**、BGRA、32bpp，和抓屏/PNG 的行顺序一致，不需要翻转。系统另外会自动合成
  CF_BITMAP；三份应用数据都是即时数据；
- **不要把 CF_DIBV5 改回 V5 + `BI_BITFIELDS`**：`super_native_extensions 0.8.24` 在 Windows
  上优先 CF_DIBV5，再给 DIB 前补一个 `bfOffBits=0` 的 14 字节 BMP 文件头并交给 WIC。
  Windows 11 22631 的变体实验结果如下（同一份 2560×1440 BGRA 像素，仅改头与需要时翻行）：

  | DIB 形态 | top-down | bottom-up |
  | --- | --- | --- |
  | V5(124) + BI_BITFIELDS（有/无 alpha mask） | WIC FAIL `0x88982F60` | WIC FAIL `0x88982F60` |
  | V5(124) + BI_RGB（mask 清零或保留） | WIC OK | WIC OK |
  | V4(108) + BI_BITFIELDS | WIC FAIL `0x88982F60` | WIC FAIL `0x88982F60` |
  | V4(108) + BI_RGB | WIC OK | WIC OK |
  | INFO(40) + BI_RGB | WIC OK | WIC OK |
  | INFO(40) + 3 个 RGB mask + BI_BITFIELDS | WIC OK | WIC OK |
  | INFO(40) + 4 个 RGBA mask + BI_ALPHABITFIELDS | WIC FAIL `0x88982F07` | WIC FAIL `0x88982F07` |

  这组数据排除了“负高度本身不兼容”：决定因素是 WIC 对这个 `bfOffBits=0` 合成 BMP 的
  header/compression 组合。最终 V5 选择规范上不矛盾的 `BI_RGB` + 全零 masks；原始 PNG
  负责无损 alpha，也让 super_clipboard 直接读 `PNG`，不再触发 DIB→WIC 合成；
- **内存契约**：`GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT)`，拷完 `GlobalUnlock`；
  `SetClipboardData` 成功后所有权归系统（**不** free、**不** write），失败立刻 `GlobalFree`；
  每次成功 `OpenClipboard` 都 `CloseClipboard`（写入失败也要关）；
- **重试**：`OpenClipboard` 最多 5 次、每次间隔 20ms（≈80ms），失败串进错误信息：
  `OpenClipboard failed after 5 attempts (~80 ms): Win32 error 5; another process may be holding
  the clipboard open`。禁止无限循环；
- PNG → RGBA 用 `png` crate 解码，调色板/灰度/16 位先 `normalize_to_color8()` 归一化，
  不假设“只有自己产出的 PNG”。

#### 踩过的坑：`Isolate.run` 闭包会把 `DynamicLibrary` 塞进 isolate 消息

`native_bridge.dart` 的剪贴板日志（`copyPngToClipboard` 里的 `then/onError` 闭包）捕获了
`this`，而 Dart 把**同一方法帧里的所有闭包放在同一个上下文**里：于是 `Isolate.run` 的闭包
连带 `NativeBridge` 实例（含 `DynamicLibrary`）一起被编组，发送阶段直接抛

```text
Invalid argument(s): Illegal argument in isolate message: (object is a DynamicLibrary)
<- Instance of 'NativeBridge' (from package:hax_shot/native/native_bridge.dart)
```

**native 侧根本不会被调到**，所以“主 isolate 直接调 DLL”的脚本全绿，UI 点“复制”却必失败。

规则：**`Isolate.run` 只能写在 static 方法里**，且那个方法帧里不能有别的捕获 `this` 的闭包。
现在的形态是 `copyPngToClipboard`（检查参数）→ `_copyPngToClipboardWithLog`（日志闭包）→
`_copyPngInWorker`（static，唯一的 `Isolate.run`）。`captureScreen()` / `encodePng()` 没这个问题：
前者帧里只有 isolate 闭包、闭包体内只碰静态单例；后者帧里只有局部变量
（`pixels`/`width`/`height`/`expected`），没有任何捕获 `this` 的同级闭包。

判定方法：异常信息里出现 `DynamicLibrary` 就说明闭包上下文带上了实例，改法就是把
`Isolate.run` 挪进 static 方法。

#### 开机自启动（`lib/features/settings/autostart_service.dart`）

- 显式三平台选择（macOS / Windows / Linux），**没有** `else = Linux`；Windows 走
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下名为 `HaxShot` 的值，
  数据是带引号的当前 exe 绝对路径；
- 用 `package:ffi` 直接调 advapi32（`RegCreateKeyExW` / `RegQueryValueExW` /
  `RegSetValueExW` / `RegDeleteValueW`），**不是** `reg.exe`：注册表 API 自己返回 LSTATUS，
  失败原因（`LSTATUS 5（拒绝访问）`）能原样写进诊断日志；
- `HKEY_CURRENT_USER` 必须传**符号扩展**后的 `0xFFFFFFFF80000001`（= -2147483647）；
  传 `0x80000001` 系统不认这个预定义句柄；
- `isEnabled()` 是“值 == 当前 exe”，不是“存在同名值”：ZIP 换目录后值还在但指向旧路径，
  这时返回 false 并写一条 `autostart_stale_value` 警告；`setEnabled(true)` 写完**回读校验**，
  不一致就抛错不报成功；`setEnabled(false)` 只删 `HaxShot` 这一个值（幂等，值不存在也算成功）；
- 系统“任务管理器 → 启动”页的禁用状态存在 `StartupApproved`，应用**不去改**它，
  只在设置页文案里提示用户去任务管理器恢复；
- `queryString()` 读 `REG_SZ` 必须有界：`REG_SZ` 不保证带终止 NUL、长度也不可信
  （用户 / 策略软件 / 损坏的值都可能写出无终止 NUL 的字节）。现在拒绝奇数字节数与
  > 64 KiB 的值，多分配一个 UTF-16 unit 保证缓冲区末尾是 NUL，按 `size ~/ 2` 手工扫描
  终止 NUL 后用 `toDartString(length:)` 转换——**禁止**无界的 `toDartString()`（它会越过
  `calloc` 分配区一直扫到内存里第一个 NUL）。`NtSetValueKey` 能写出真正无 NUL 的 `REG_SZ`，
  仓库外脚本用「页末 + PAGE_NOACCESS」验证过：修前在 `Utf16Pointer._toUnknownLengthString`
  上 0xC0000005，修后正常截断。

#### 保存路径与文案

- `capture_page.dart`：Windows 不指定 `initialDirectory`（`USERPROFILE\Pictures` 可能被
  OneDrive 重定向或不存在），非 Windows 保持 `$HOME/Pictures`；
- `Win` 标签与平台文案：`shortcut_service.dart` 的 `bindingDisplayLabel`、
  `shortcut_settings_page.dart` 的录制即时 label / `_modifierHint` / `_autostartSubtitle`、
  `first_run_guide.dart` 的权限说明；只有 macOS 提屏幕录制权限。

#### 托盘菜单必须 `bringAppToFront: true`

`tray_manager` 的 `popUpContextMenu()` 默认 `bringAppToFront = false`，插件于是**不调**
`SetForegroundWindow(owner)`。`TrackPopupMenu` 的契约是 owner 窗口必须是前台窗口，否则菜单
虽然弹了出来却收不到键盘/鼠标：**点菜单外面、按 Esc 都不会关**（本机实测：默认值下点任务栏
菜单永远不消失；传 true 之后立刻正常）。所以 `lib/app.dart` 的 `_popUpTrayMenu()` 在 Windows
上带 `bringAppToFront: true`（这个参数只对 Windows 生效；Linux 仍然直接 return，AppIndicator
自己会弹菜单）。该参数被上游标了 `@Deprecated`，用 `// ignore: deprecated_member_use` + 注释
说明理由。

#### 本机实测（2026-09-19，3840x2160 @150% 单屏）

剪贴板（仓库外脚本直调 DLL，以及真实 `NativeBridge` 路径的临时入口）：

```text
clipboard formats: 49448(PNG), 17(CF_DIBV5), 8(CF_DIB), 2(CF_BITMAP，由系统合成)
CF_DIBV5: size=3840x-2160 bitCount=32 compression=0 globalSize=33177724
CF_DIB  : size=3840x-2160 bitCount=32 compression=0 globalSize=33177640
super_clipboard 同形路径（补 bfOffBits=0 的 BMP 头）：CF_DIBV5 WIC OK 3840x2160；CF_DIB WIC OK
PNG ↔ DIBV5 逐点比对：8/8 RGB 全等；BGRA/RGBA 误读 0/8；上下翻转误读 1/8
PerMonitorV2 屏幕 ↔ PNG：12/12 RGB 全等；翻转仅 3/12；R/B 互换 0/12
透明 PNG 探针：DIBV5 四像素 alpha=0,64,128,255，与输入完全一致
写剪贴板的进程退出、再等 2 秒后仍能读回；此时 CLiper 进程正在运行，格式没有被破坏
OLE IDataObject：PNG / CF_DIBV5 / CF_DIB 的 QueryGetData + GetData 全部 hr=0；PNG SHA-256 与源文件相同
.NET Clipboard.GetImage()：OK 3840x2160 Format32bppRgb
占用路径：OpenClipboard failed after 5 attempts (~80 ms): Win32 error 5（有限重试，不卡死）
真实 NativeBridge 路径的日志格式标签：clipboard_copy_success format=PNG+CF_DIBV5+CF_DIB
```

上面的系统侧证据不等于 CLiper 历史 UI / Paint / 浏览器已经由用户验收；这些仍按 18.17
保留为“待用户”。注册格式 id（本次是 49448）由 Windows 动态分配，代码只能依赖名称 `PNG`，
不能把数字写死。

自启动（临时入口 + 独立 `reg query` 交叉验证，验完恢复原状）：

```text
setEnabled(true)  → reg query: HaxShot  REG_SZ  "<Release 目录>\hax_shot.exe"
外部写陈旧值      → isEnabled() == false（回读校验，不是“存在同名值就算开”）
中文+空格路径     → REG_SZ 原样写入/读回
setEnabled(false) → HaxShot 值消失，同键下 HaxShotKeepMe 没被动
```

托盘（脚本用插件自己的回调消息 `WM_USER+1` + `WM_LBUTTONUP`/`WM_RBUTTONUP` 模拟图标点击，
等价于 `Shell_NotifyIcon` 的通知；菜单项用 `MN_GETHMENU` + `GetMenuItemRect` 定位后真点）：

```text
右键 → 菜单窗口（#32768）出现；点菜单外面 → 菜单关闭（修 bringAppToFront 之后）
点“立即截屏”菜单项 → 日志 menu_capture_trigger → capture_child_started → overlay_ready
点“退出”菜单项 → 进程退出
```

本机测不了（**待验**）：多屏/混合 DPI 下的剪贴板与保存对话框、真实鼠标点托盘图标
（脚本只能模拟插件的回调消息）、睡眠唤醒后的托盘图标与快捷键、Windows 剪贴板历史（Win+V）、
Paint / 浏览器 / IM 的手动粘贴。

### 18.16 Phase 6：平台分支审查结论（§38–§40）

审查方式：在 `lib/` 下逐条跑 §39 的七条命令（`Platform.isMacOS` / `isLinux` / `isWindows`、
`gsettings`、`GNOME`、`HOME`、`/tmp/`），每条命中回答两个问题——“Windows 会误入这个分支吗”、
“不走的平台会因此看到错误文案或错误行为吗”。

结论：**没有“else = Linux / else = macOS”式的服务分发**，所有服务都显式列三个平台并以
`UnsupportedError` 收尾（`shortcut_service.dart`、`autostart_service.dart`）。逐条结论：

| 命中 | 结论 |
| --- | --- |
| `shortcut_service.dart:73-77`、`autostart_service.dart:19-24` | 已按 §26/§32 改成显式三平台；本轮无改动 |
| `native_bridge.dart:47/138/168-169/399-407` | DLL 候选路径、剪贴板格式标签都有 Windows 分支，无需动 |
| `single_instance_guard.dart:39-52`、`diagnostic_log.dart:63-78`、`capture_request_channel.dart:38-53` | 三处都是 macOS / Windows / Linux 三分支（Windows 用 `%LOCALAPPDATA%\hax_shot`），无需动；`%LOCALAPPDATA%` 缺失时回退 `HOME`/cwd 的行为记为已知限制（§56.3） |
| `main.dart:119-128` | `captureMode && Platform.isMacOS`、`backgroundColor` 的二分是**有意**的：Windows 浮层由 `capture_window_bridge` 摆位，不走 macOS 的 `.screenSaver` 分支，也不需要隐藏标题栏的替代方案 |
| `app.dart:550-556`、`app.dart:769` | `_recoverShortcut`：Windows 只做 resumed 后重注册一次（那条梯度是给 Carbon 实测行为写的）；`_popUpTrayMenu`：Linux 的 AppIndicator 自己弹菜单，重复调用会弹两次，所以保持 `return`；Windows 已加 `bringAppToFront: true`（§6.7） |
| `app.dart:155-165`、`window_visibility.dart:17`、`capture_overlay_window.dart:120/131/158` | §14.5 / §14.7 / §15 的落点，Windows 分支都在，无需动 |
| `first_run_guide.dart:32-38`、`shortcut_settings_page.dart:123-155/537`、`shortcut_service.dart:104-109` | 平台文案：Windows 显示 `Win`、HKCU Run 说明，没有 GNOME/macOS 说法（§36），无需动 |
| `screen_capture_permission.dart:26`、`capture_permission_flow.dart` | `if (!Platform.isMacOS) return;` + `isMacOS()` 显式传参：Windows 不会掉进 macOS 授权引导，查询失败也只进平台无关的失败面板 |
| `hard_exit.dart` | Windows 上 `Process.killPid(..., sigkill)` 忽略信号、直接终止进程，按 §39 不重写 |
| `app_lifecycle_bridge.dart` | 只注册接收 handler、从不 `invokeMethod`（事件由 macOS 原生侧发），Windows 上是空实现，安全 |
| `rounded_window.dart:27` | Win/Linux 共享 `ClipRRect`、macOS 交给系统裁圆角，是有意设计 |
| `hotkey_binding.dart` | 绑定串三平台共用；`windowsVirtualKeyCode` 是 Windows 唯一入口，没有把 Flutter `keyId`、USB HID usage 或 Carbon 键码当 VK（§25） |
| `gnome_shortcut_service.dart`、XDG 自启动里的 `gsettings` / `XDG_*` | 都封在 Linux 服务内部，Windows 不会执行到；`lib/` 里已没有 `/tmp/` 字面量（`main.dart` 用 `Directory.systemTemp`） |

**本轮唯一的代码改动**是 `lib/native/native_bridge.dart` 里 `_copyPngToClipboardWithLog` 的注释：
原文写“只有 Linux 放到 worker isolate”，而代码是“macOS 同步、其余平台进 worker isolate”，
Windows 正好落在 worker 里——这也是正确行为（`copy_png_impl` 阻塞等自己的剪贴板专职线程，
最长是 `OpenClipboard` 的 5×20ms 重试窗口，放主 isolate 会卡住 platform 线程）。只改了注释，
没有改行为。

按 §40 **不新增** `DesktopPlatform` 之类的抽象：现在要合并的只剩“文档/注释里的平台描述”，
不值得为此加一层。

### 18.17 Phase 7：用户验收矩阵状态（§41–§47）

状态只有四种：`已验证`（用户亲测 + 现象）、`待用户`（代码已就绪，等用户跑）、`缺设备`、
`已知不支持`。**Agent 不替用户勾“已验证”**；截至 18.15 的本机证据都来自脚本直调 DLL /
模拟托盘消息，不能当成端到端验收。

三维前提（本机实物条件见 18.1）：单显示器 `\.\DISPLAY1`（0,0 起）、3840x2160 @150%、
Windows 11 x64。因此“副屏 / 负坐标 / 混合 DPI / 三屏 / Win10”本机一律缺设备。

| # | 项 | 状态 |
| --- | --- | --- |
| 1 | Win11 单屏启动（托盘常驻、不闪窗、不占任务栏） | 待用户 |
| 2 | Win10 x64 启动 | 缺设备（本机只有 Win11） |
| 3 | host + capture 两进程（PID 不同、锁与 ACK 可追） | 待用户 |
| 4 | 重复 capture（第二次不显示窗口） | 待用户 |
| 5 | 含空格 / 中文路径启动 | 待用户 |
| 6 | 退出 host（托盘消失、锁释放、快捷键失效） | 待用户 |
| 7 | 单屏截图（尺寸 / 方向 / 颜色） | 待用户 |
| 8 | 双屏（鼠标在主 / 副） | 缺设备 |
| 9 | 左侧副屏（负坐标，不偏移不 clamp） | 缺设备 |
| 10 | 混合 DPI 副屏 | 缺设备 |
| 11 | 三屏 | 缺设备 |
| 12 | 物理客户区契约（§13.5 三项一致） | 待用户 |
| 13 | 常规浏览器 / 桌面非黑图 | 待用户 |
| 14 | HDR / 独占全屏 / 受保护内容 | 已知不支持（§66） |
| 15 | 选区 / 矩形 / 箭头 / 文字（控制点不入导出） | 待用户 |
| 16 | Esc（退出且锁释放） | 待用户 |
| 17 | 保存 PNG（尺寸 = 选区物理像素） | 待用户 |
| 18 | 复制到剪贴板（Paint 可粘） | 待用户 |
| 19 | 浏览器 / IM 至少一个可粘 | 待用户 |
| 20 | capture 退出后仍可粘贴（硬门槛） | 待用户 |
| 21 | AI 面板（可缩放、可关闭、转后能再截） | 待用户 |
| 22 | 默认快捷键 `Alt+Shift+Z` | 待用户 |
| 23 | 改绑 / 冲突 / 回滚（UI 不误报成功） | 待用户 |
| 24 | 删除后重启仍禁用 | 待用户 |
| 25 | 自启动开关（可开可关、不双实例） | 待用户 |
| 26 | 平台文案（无 GNOME / macOS 说法） | 待用户 |
| 27 | 日志可查（快捷键失败 code + capture 链） | 待用户 |
| 28 | 睡眠 / 唤醒后快捷键可用或可恢复 | 待用户 |

§46 的负坐标项按上表第 9 项记缺设备；§47 的 DPI 必测项里，“手头这一组（单屏 150%）”
已具备但整体矩阵仍是待用户，“主屏 + 外接 100%（或任何混合组合）”“窗口跨屏后摆浮层”
均缺设备——**不得**因此写“DPI 全覆盖”。

用户自查日志（日志是 UTF-8，Windows PowerShell 里不带 `-Encoding UTF8` 会把中文显示成乱码）：

```powershell
$log = "$env:LOCALAPPDATA\hax_shot\logs\hax_shot.log"
Get-Content $log -Tail 50 -Encoding UTF8
Get-Content $log -Encoding UTF8 |
  Select-String -Pattern 'shortcut_trigger|spawn_success|child_started|lock_busy|capture_ready|overlay_ready|failed'
```

`Select-String -Encoding` 是 PowerShell 7 才有的参数；用 Windows PowerShell 5.1 时按上面的
管道写法先读成字符串再匹配（事件名是 ASCII，中文只在 `message` 字段里）。

本轮按 §56.3 记录、**不修**的两个限制：

- `diagnostic_log.dart` 的注释说“阻塞式独占锁”，实际用的是 `FileLock.exclusive`（非阻塞）：
  极端情况下会抢锁失败并丢掉一条事件，“日志一定完整”不是无条件承诺；
- `%LOCALAPPDATA%` 缺失时日志 / 锁 / ACK 三处都会退到 `HOME`/当前目录，非标准环境会带出
  工作目录依赖（`single_instance_guard.dart`、`capture_request_channel.dart`、
  `diagnostic_log.dart` 一致）。

### 18.18 托盘图标“看不见”不是没注册（Windows 11 溢出菜单）

判断“图标真的注册上了”不能只看 `tray_init_success`：那只是插件调用没有抛异常。
真正的判据是原生 `Shell_NotifyIconGetRect` **返回非 0**——图标在托盘区域里有一个 rect。

本机实测（Win11 22631、单屏 3840x2160，现象是用户报“托盘没有图标、点不到菜单”）：

```text
Shell_NotifyIconGetRect → rect=(3390,2088)-(3438,2160)   ← 图标已注册，在屏幕右下角
HKCU\Control Panel\NotifyIconSettings 里有该 exe 的记录，IsPromoted 为空（未被提升）
对比截图：应用未运行时任务栏没有 `^`，应用运行中 `^` 出现（图标就在它内部）
```

结论：Windows 11 默认把新程序的图标收进“显示隐藏的图标”溢出菜单。**程序无法自行把图标
提升到任务栏**（系统不提供这种 API），只能由用户点 `^` 后把图标拖到任务栏固定。所以只在
README 与首次启动欢迎页各给一句提示，不要再往代码里加“自动弹出/自动提升”之类的尝试。

看日志时注意：日志是 UTF-8，Windows PowerShell 读取要带 `-Encoding UTF8`（命令见 18.17），
否则中文 `message` 字段会显示成乱码。

### 18.19 快捷键桥的消息路由与失败面板显示失败（对抗性评审修复）

`hax_shot_code_review_luna.md` 里两条不在 18.11/18.14/18.15 范围内的失败路径，改动如下。

#### `WM_HOTKEY` 路由：注销后不能再触发

`windows_shortcut_bridge.cpp` 的 `HandleMessage` 现在要求四个条件**同时**成立才 `Fire()`：

```text
message == WM_HOTKEY && wparam == kHotKeyId && window == window_ && registered_
```

- 只认 `message + wparam` 不够：`UnregisterHotKey` **不会**清掉已经排进消息队列的
  `WM_HOTKEY`。用户刚删除 / 改绑快捷键时，队列里那条旧消息仍会被派发到这里；不检查
  `registered_` 就会凭空启动一次截图。本机用真实消息队列验证过：`RegisterHotKey` →
  `PostMessage(WM_HOTKEY)` → `UnregisterHotKey`（返回 TRUE）→ `PeekMessage` 仍能取到该消息；
  旧路由 fires=1，新路由 fires=0；
- 加 `window == window_` 是因为 `wParam` 只有 id，同一个 HWND 上别的组件（或消息被投给
  子窗口）也可能用同一个 id，不能替别人消费消息；
- `Fire()` 里再判一次 `registered_` 做兜底；钩子已经保证“注册失败 / 注销 / 析构后不会再回
  调 Dart”；
- Dart 侧（`windows_shortcut_service.dart` 的 `WindowsShortcutBridge.unregister()`）在调原生
  **之前**先把 `_onTriggered` 摘掉：native → Dart 的 `triggered` 是异步投递的，用户点“删除”
  时可能还有一条已发出的触发消息在路上；注销失败再把回调恢复（系统里可能还注册着，
  不能变成“按了没反应”）。`register()` 失败也清回调。

#### 失败面板显示失败不能留下“隐藏 + 持锁”进程

`capture_permission_flow.dart` 的 `revealWindow()` 改为返回 `bool`：

- `showWindow()` 失败（低频但一旦发生用户就完全看不到面板）→ 写
  `window_ready_failed` / `WINDOW_REVEAL_FAILED`，并调注入的 `quit()` 结束捕获进程；
  `capture_page.dart` 的 `_revealFailurePanel()` 再 `exitProcess()` 硬退出兜底——否则会留下
  一个隐藏且持有捕获锁的进程，表现为“按快捷键没反应”；
- `windowManager.focus()` 失败只降级为 `window_ready_failed` warning：窗口已经显示了，
  不影响用户看到面板。
