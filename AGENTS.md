# AGENTS.md

hax_shot 的项目级约定。和 `~/.pi/agent/AGENTS.md` 的通用约定冲突时以本文件为准。

## 不要跑测试

默认**不跑**测试，也不要为了“验证”反复重建、反复截图量像素：

- 不跑 `flutter test`、`cargo test`、`xcodebuild test`；
- 改完直接构建 + 安装（`scripts/install_macos_app.sh`、`scripts/build_macos_dmg.sh`），
  让用户自己运行 App 确认效果；
- `dart format`、`flutter analyze` 这类秒级检查可以保留，但别把它们当成“测试通过”的
  依据去反复跑。

**例外**：问题难以定位，或者同一处改了几次仍然没解决时（例如窗口圆角、退出后快捷键
仍生效这类实测才发现的问题），才写针对性的测试或脚本去量，并且一次把要量的一次问清，
不要来回跑测试-重建-再看。

## 其他

- 技术细节、踩过的坑、为什么不能那么写，都记在 `docs/development-guide.md`，改代码时
  顺手同步它；
- macOS 本机构建一律用 `scripts/install_macos_app.sh --dev-cert`。ad-hoc 签名没有证书，
  屏幕录制授权只能绑 cdhash，**每次重建都会失效**；而系统设置里的开关看着还是开的、
  并且不再弹授权框——表现是“快捷键/截图没反应”而不是报错，极易被当成代码 bug。
  绑定证书后重建不掉授权，记录形态与恢复办法见 `docs/development-guide.md` 6.2。
- 排查 macOS “按了没反应/不起作用”类问题，先看进程和权限（`pgrep -f -- '--capture'`、
  读 `kTCCServiceScreenCapture` 那条记录），确认了再动代码；两个进程共用
  `_startCapture()`，先点菜单栏“立即截屏”也能一步分叉。
- 构建产物：`build/macos/Build/Products/Release/hax_shot.app`，分发镜像
  `build/macos/HaxShot-<版本>-arm64.dmg`；debug 镜像
  `build/macos/HaxShot-<版本>-arm64-debug.dmg`（`scripts/build_macos_dmg.sh --debug [--install]`，
  本机联调用，ad-hoc 签名不公证）。
