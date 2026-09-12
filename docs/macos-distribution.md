# macOS 打包与分发

这份文档只讲**分发给别人**（不是本机自测）的链路。本机开发请用
[`development-guide.md`](./development-guide.md) 里的 `scripts/install_macos_app.sh`。

## 0. 只支持 Apple Silicon（arm64）

本项目**不支持 Intel Mac**，也不做通用二进制（universal）：

- `macos/Runner/Configs/AppInfo.xcconfig` 里 `ARCHS = arm64`，`scripts/build_macos_rust.sh`
  按 `$ARCHS` 逐架构构建 Rust dylib（当前只会走 `aarch64-apple-darwin`）；
- 产物验证：`lipo -archs /Applications/hax_shot.app/Contents/MacOS/hax_shot` 应为 `arm64`，
  `Contents/Frameworks/` 下所有框架和 `libhax_shot_native.dylib` 也都只能是 `arm64`；
- DMG 文件名固定带 `-arm64`（例如 `HaxShot-1.3.0-arm64.dmg`）。

在 Intel 机器上 macOS 自己会拦下：提示“不能打开，因为此类型 Mac 不支持”，这是预期行为，
不需要我们额外做检测。

## 1. 一条命令

```bash
# 有 Developer ID 证书时自动签名
scripts/build_macos_dmg.sh

# 明确指定身份 / 并提交 Apple 公证
MACOS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  NOTARY_PROFILE=hax-shot scripts/build_macos_dmg.sh --notarize

# 只对已有产物做验收检查
scripts/build_macos_dmg.sh --verify-only

# 本机联调用的 debug 镜像（ad-hoc 签名、不公证）：
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

## 2. 分发给别人的机器，缺哪一环会怎样

| 环节 | 缺了会怎样 | 谁提供 |
|---|---|---|
| Developer ID Application 签名 | Gatekeeper 报“无法验证开发者/已损坏”，用户打不开 | 付费 Apple Developer 账号里的证书 |
| 硬化运行时（`ENABLE_HARDENED_RUNTIME = YES`） | 无法通过公证 | 已在 `macos/Runner/Configs/Release.xcconfig` 里开好 |
| 公证 + staple | 首次打开需要用户手动右键→打开（新系统可能直接拒绝） | `xcrun notarytool` + keychain profile |
| bundle 内 framework/dylib 同身份签名 | library validation 拒绝加载 Rust dylib | `scripts/build_macos_rust.sh` 用 `EXPANDED_CODE_SIGN_IDENTITY` 签，脚本也会兜底重签 |

注意：**Apple Development 证书不能分发**，本机那把已经吊销；也没有可用于生产的
自签名方案——自签名证书只适合本机开发（见下文）。

## 3. 屏幕录制授权：为什么必须保持同一个签名身份

macOS 把“屏幕录制”授权绑在代码签名上：

- **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`）绑定的是构建产物指纹，每次重新构建都变 →
  系统设置里那条旧记录（开关看着是开的）和二进制对不上，既没权限也不再弹授权框。
- **Developer ID 签名**绑定的是证书 + bundle id → 用户授权一次之后，后续版本升级
  （甚至换版本号）都保留授权，不会反复要求授权。

所以正式分发的 app **必须**用 Developer ID 签名，不只是为了 Gatekeeper，也是为了升级时
不折腾用户。`tccutil reset` 那种修复手段只是给本地开发兜底的（见
`lib/features/settings/screen_capture_permission.dart`）。

### 本机开发：别用 `flutter run` 授权

`flutter run` 启动的 app 责任进程是终端，屏幕录制授权会记在终端上，Hax Shot 不会出现在
系统设置列表里。开发时用：

```bash
scripts/run_macos_debug.sh            # 构建 debug 并用 open 启动（Hax Shot 成为责任进程）
```

### 本机开发怎么办

开发期是 ad-hoc 签名，会反复遇到上面的错位。当前实现按 `hax_pick` 的做法处理：

- 引导页每 750ms 轮询一次授权状态，切回前台时立刻重查；检测到已授权就自动重启抓屏进程继续；
- 引导页提供「重置授权记录」＝ `tccutil reset ScreenCapture <bundle id>`，专门解开
  “开关是开的但进程没权限、也不再弹框”的死结；
- `scripts/macos_dev_cert.sh` 可以创建一个自签名的本地证书，让开发期授权跨构建稳定。
  **仅限本机开发**：自签名证书无法公证，给别人的 app 用它仍然会被 Gatekeeper 拒绝。

## 4. 别人的 Mac 上第一次运行会经历什么

```text
1. 挂载 DMG → 拖 hax_shot.app 到“应用程序” → 打开
   （已公证：直接打开；未公证：右键→打开，或去“隐私与安全性”里放行）
2. 没有 Dock 图标！它是菜单栏应用（LSUIElement），只在菜单栏右侧出现一个小图标
3. 按 ⌥Z 或点菜单栏图标 → “立即截屏”
4. 第一次会弹出自己的授权引导（小窗口，不是全屏）：
   「打开系统设置」→ 在“隐私与安全性 → 屏幕录制”勾选 Hax Shot → 回到 app
   → 检测到授权后自动继续截图
5. 想换快捷键：菜单栏图标 → “设置” → 录制组合键（默认已经是 ⌥Z）
6. 想用 AI：AI 面板里填 DeepSeek API Key
```

#### 升级后一定要退出旧实例

全局快捷键是**正在运行的那个实例**注册的。如果旧版本还在跑（菜单栏里那个图标），
即使你把新版本拷进 /Applications，按快捷键触发的仍然是旧实例 —— 表现就是“快捷键
截屏看起来和托盘截屏不是同一个版本”。`scripts/install_macos_app.sh` 会先 `pkill`
再替换 bundle，所以走脚本安装/升级不会踩这个坑。

## 已知会让人困惑的点

- **第 2 步**：菜单栏应用没有 Dock 图标，新用户容易以为没启动。已实现首次启动欢迎窗口
  （`lib/features/onboarding/first_run_guide.dart`，标记 `hax_shot.onboarding_seen`），
  说明图标位置、快捷键和首次授权，并带「打开设置」入口。
- **菜单栏图标可能被菜单栏管理工具藏起来**（本机就是 Bartender 把它收进隐藏区），
  所以默认快捷键 `⌥Z` 是必需的兜底入口。
- **API Key 目前存在 shared_preferences（明文 plist）**。正式分发建议改存 Keychain。

## 5. 卸载

```bash
scripts/install_macos_app.sh                   # 重新安装（会先退出正在运行的旧实例）
scripts/uninstall_macos_app.sh                 # 卸载并清掉用户数据
scripts/uninstall_macos_app.sh --dry-run       # 先看会做什么
scripts/uninstall_macos_app.sh --keep-prefs    # 保留快捷键等偏好设置
scripts/uninstall_macos_app.sh --dir ~/Apps    # 应用装在别处
```

清掉的东西：运行中的进程、`<dir>/hax_shot.app`、`~/Library/LaunchAgents/<bundle id>.plist`
（含 `launchctl bootout`）、屏幕录制授权记录（`tccutil reset`）、偏好设置 plist，以及系统
生成的 `Saved Application State` / `Caches` / `HTTPStorages` 目录。开发用自签名证书和
`build/macos/` 里的构建产物不在范围里，脚本结尾会提示对应命令。

## 6. 发布前检查清单

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
DMG 能挂载且内含 hax_shot.app / Applications 快捷方式
Gatekeeper 接受 app（spctl）
DMG 已公证并 stapled
```
