# CI 与 GitHub Release

Hax Shot 的发布目标是让“代码合并”和“发布安装包”分开：普通 `main` 分支 push 只更新源码、
只跑 [`verify.yml`](../.github/workflows/verify.yml) 的检查；只有推送版本 tag 时，
[`release.yml`](../.github/workflows/release.yml) 才会构建三个平台的安装包并发布
GitHub Release。

## 1. 触发规则

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

以下操作会触发打包：

```bash
git push origin v1.3.0
```

### 干跑（不发布）

`release.yml` 还支持 `workflow_dispatch`：构建 job（Linux、macOS）全部执行并上传
Actions artifact，但最后一步发布 Release 只在 tag push 时运行。改打包脚本或工作流
之后，先在 Actions 页面手动 Run workflow（或 `gh workflow run release.yml`）干跑一次，
确认绿了再打 tag——不要用真 tag 试错。

## 2. 版本约定

tag 必须与 `pubspec.yaml` 的应用版本匹配，但不包含构建号。工作流第一步就会检查这个关系，
不一致立刻失败，避免把错误版本上传到 Release。

| `pubspec.yaml` | Git tag | Release Assets |
|---|---|---|
| `1.3.0+1` | `v1.3.0` | `HaxShot-1.3.0-arm64.dmg`、`hax-shot_1.3.0+1_amd64.deb`、`hax-shot-1.3.0-1.x86_64.rpm` |

其中：

- `1.3.0` 是应用版本，也是 DMG 名字和 RPM 的 Version；
- `+1` 是 DEB 的完整版本（`1.3.0+1`）和 Fedora RPM 的 Release；
- RPM 在 Fedora 本机构建时会带 `.fc44`，在 CI（Ubuntu 的 rpmbuild）里没有这个发行版后缀；
- `v1.3.0` 是 GitHub Release 的 tag 和页面名称。

## 3. 发布流程

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
git commit -m "release: v1.3.0"
git push origin main
```

需要发布时，在**已经推送的**那个 commit 上创建带注释的 tag：

```bash
git tag -a v1.3.0 -m "Release v1.3.0"
git push origin v1.3.0
```

## 4. GitHub Actions 做什么

`release.yml` 分成四个 job：

| job | runner | 作用 |
|---|---|---|
| `preflight` | `ubuntu-24.04` | 校验 tag 与 `pubspec.yaml` 版本一致（会消耗 macOS 分钟数之前就失败） |
| `linux` | `ubuntu-24.04` | 构建 Linux release bundle，再打 `--skip-build` 的 DEB 和 RPM，校验两个包都带上 `libhax_shot_native.so` |
| `macos` | `macos-14`（arm64） | 校验 runner 架构，签名（可选）→ 公证（可选）→ 打 DMG，校验 app、Rust dylib 都是 arm64 |
| `release` | `ubuntu-24.04` | 汇总两个平台的产物，创建或更新 GitHub Release |

每个平台 job 还会把自己的包存一份 30 天有效的 Actions artifact，方便排查。

Dart/Rust 的 analyze 和 test 不在这里重复跑：它们由 `main`/PR 上的 `verify.yml` 负责
（Linux 与 macOS 两个 job），tag 应该指向已经过检查的 commit。

如果同一个 tag 的 Release 已经存在（例如补传 macOS 产物），`release` job 会用
`--clobber` 覆盖同名资产，而不会创建第二个 Release。

## 5. macOS 签名与公证（分发必需）

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
[macOS 打包与分发](./macos-distribution.md) 的说明告知用户 DMG 只用于内部测试。

## 6. 发布后的检查

在仓库的 **Releases** 页面确认：

- Release tag 与 `pubspec.yaml` 版本一致，且不是 Draft；
- Assets 里三个文件都在：`HaxShot-<版本>-arm64.dmg`（或未签名时的
  `HaxShot-<版本>-arm64-unsigned.dmg`）、`hax-shot_<版本>_amd64.deb`、
  `hax-shot-<版本>-<release>.x86_64.rpm`；
- 如果只有 `-unsigned` DMG，Release 正文顶部应该已经有未签名警告；
- Release notes 由 `--generate-notes` 生成（会带上本次 tag 之前的 PR/commit 列表）。

验证 macOS 产物：

```bash
hdiutil attach HaxShot-1.3.0-arm64.dmg          # 能挂载且内含 hax_shot.app
lipo -archs /Volumes/Hax\ Shot/hax_shot.app/Contents/MacOS/hax_shot   # arm64
spctl -a -vvv -t exec /Volumes/Hax\ Shot/hax_shot.app                 # 有签名+公证时 should be accepted
```

验证 Linux 产物（Fedora GNOME Wayland / Ubuntu GNOME Wayland）：

```bash
sudo dnf install ./hax-shot-1.3.0-1.x86_64.rpm        # 或 sudo apt install ./hax-shot_1.3.0+1_amd64.deb
/usr/share/hax-shot/install-gnome-shortcut.sh
```

## 7. 失败处理

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
