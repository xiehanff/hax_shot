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
- 构建产物：`build/macos/Build/Products/Release/hax_shot.app`，分发镜像
  `build/macos/HaxShot-<版本>-arm64.dmg`。
