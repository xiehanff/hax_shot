import 'dart:io';

import 'package:flutter/material.dart';

/// 给非全屏窗口加圆角。
///
/// macOS 的 titled 窗口由系统自己裁圆角（角外直接是桌面），Flutter 再裁一遍反而会在
/// 系统圆角和 Flutter 圆角之间留一圈窗口背景，看起来就是“有圆角但不透”。所以只在
/// Windows/Linux 上需要这里的 ClipRRect：那两个平台的窗口本身没有圆角，靠它 + 窗口
/// 背景透明做出圆角（`lib/main.dart` 的 `backgroundColor` 在这两个平台取
/// `Colors.transparent`，所以剪掉的四角露出的是桌面而不是黑角）。
///
/// macOS 不需要这里的 ClipRRect 也正是因为底色不透明：系统裁完圆角之后，Flutter 再裁
/// 一遍只会多出一圈窗口底色。
///
/// 全屏浮层（截图框选、`CapturePage`）不要用它：那里必须铺满直角。
class RoundedWindow extends StatelessWidget {
  const RoundedWindow({required this.child, super.key});

  /// 取值接近 macOS 原生窗口圆角，三个平台统一。
  static const double radius = 12;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isLinux) {
      return child;
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}
