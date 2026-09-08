# CI 与 GitHub Release

Hax Shot 的发布目标是让“代码合并”和“发布 RPM”分开：普通 `main` 分支 push 只更新源码，不消耗 Linux 打包流程；只有推送版本 tag 时，GitHub Actions 才构建并上传 Fedora RPM。

## 1. 触发规则

工作流位于：

```text
.github/workflows/build-rpm.yml
```

它只有一个触发器：

```yaml
on:
  push:
    tags:
      - 'v*'
```

因此以下操作不会打包或创建 Release：

- `git push origin main`；
- 修改 PR；
- 在 Actions 页面手动点击运行（工作流没有 `workflow_dispatch`）。

以下操作会触发打包：

```bash
git push origin v1.3.0
```

## 2. 版本约定

tag 必须与 `pubspec.yaml` 的应用版本匹配，但不包含构建号：

| `pubspec.yaml` | Git tag | RPM 结果 |
|---|---|---|
| `1.3.0+1` | `v1.3.0` | `hax-shot-1.3.0-1.fc44.x86_64.rpm` |
| `1.2.1+1` | `v1.2.1` | `hax-shot-1.2.1-1.fc44.x86_64.rpm` |

工作流开始时会主动检查这个关系。tag 和版本不一致时立即失败，避免把错误版本的 RPM 上传到 Release。

其中：

- `1.3.0` 是应用和 RPM 的 Version；
- `+1` 是 Fedora RPM 的 Release；
- `fc44` 由 Fedora RPM 构建环境追加；
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

确认工作树只包含本次发布内容后，先提交并推送主分支：

```bash
git add .
git commit -m "feat: ..."
git push origin main
```

需要发布时，先在 `pubspec.yaml` 更新版本并提交，再创建带注释的 tag：

```bash
git tag -a v1.3.0 -m "Release v1.3.0"
git push origin v1.3.0
```

## 4. GitHub Actions 做什么

`build-rpm.yml` 按以下顺序执行：

1. Checkout 被推送的 tag；
2. 安装 Flutter Linux、GTK、PipeWire、GStreamer、RPM 和 `patchelf` 构建依赖；
3. 安装 Rust 和 FVM，并解析项目固定的 Flutter SDK；
4. 运行 `flutter analyze`、`flutter test`、`cargo fmt`、`cargo check` 和 `cargo test`；
5. 调用 `scripts/build_linux_rpm.sh` 构建 RPM；
6. 同时保存一个 30 天有效的 Actions artifact，方便排查；
7. 创建对应的 GitHub Release，并把 RPM 上传到 Release Assets。

如果同一个 tag 的 Release 已经存在，工作流会使用 `--clobber` 替换同名 RPM，而不会创建第二个 Release。

## 5. 发布后的检查

在仓库的 **Releases** 页面确认：

- Release tag 与 `pubspec.yaml` 版本一致；
- Assets 中存在 `hax-shot-*.rpm`；
- Release 不是 Draft；
- RPM 文件架构为 `x86_64`。

下载 RPM 后，在 Fedora GNOME + Wayland 机器上安装：

```bash
sudo dnf install ./hax-shot-1.3.0-1.fc44.x86_64.rpm
/usr/share/hax-shot/install-gnome-shortcut.sh
```

## 6. 失败处理

- **版本检查失败**：确认 tag 去掉 `v` 后等于 `pubspec.yaml` 中 `+` 前的版本；
- **Flutter/Rust 检查失败**：先复现对应的本地命令，不要直接重推同一个 tag；
- **RPM 构建失败**：检查 `scripts/build_linux_rpm.sh` 和 Fedora 运行依赖声明；
- **Release 上传失败**：确认仓库 Actions 有 `contents: write` 权限，或重新运行同一个 tag 的 workflow；
- **需要重新上传同名 RPM**：修复后删除并重新创建 tag，或者在 Actions 中重跑同一个 tag，工作流会覆盖同名资产。

一句话总结：**main push 只更新代码，`git push origin vX.Y.Z` 才构建 RPM 并发布 GitHub Release。**
