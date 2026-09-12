import 'dart:io';

import 'package:flutter/material.dart';

import '../window/panel_chrome.dart';
import '../window/rounded_window.dart';

/// 首次启动的欢迎页。
///
/// 托盘/菜单栏应用没有 Dock 图标，双击启动后屏幕上不会出现任何东西，新用户会以为
/// 没启动。这一页把三件事说清楚：图标在哪、快捷键是什么、第一次截图会要权限。
///
/// 版式是“居中开场 + 卡片”：顶部只有一条可拖拽的细条（右上角关闭），中间是灰蓝
/// 徽标 + 标题 + 说明，下面一张卡片放快捷键和图标位置，最后是两个操作按钮。
/// 视觉全部来自 `window/panel_chrome.dart`。
class FirstRunGuide extends StatelessWidget {
  const FirstRunGuide({
    required this.shortcutLabel,
    required this.onOpenSettings,
    required this.onClose,
    super.key,
  });

  /// 当前快捷键的展示文案（例如 `⌥+Z`），为空表示还没设置。
  final String shortcutLabel;

  final VoidCallback onOpenSettings;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final trayLocation = Platform.isMacOS ? '菜单栏右侧' : '系统托盘';
    final shortcut = shortcutLabel.isEmpty ? '未设置' : shortcutLabel;

    return RoundedWindow(
      child: Scaffold(
        backgroundColor: PanelColors.bg,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 标题在下面的开场区，所以顶部条只留拖拽区和关闭按钮。
            PanelHeader(height: 56, onClose: onClose),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Center(
                      child: PanelIconBadge(
                        icon: Icons.screenshot_monitor_outlined,
                        size: 56,
                        iconSize: 27,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Hax Shot 已在后台运行',
                      textAlign: TextAlign.center,
                      style: PanelText.heroTitle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '它没有主窗口，启动后只在$trayLocation显示一个小图标，'
                      '所有操作都从那个图标开始。想改快捷键或开机自启动，'
                      '打开设置页即可。',
                      textAlign: TextAlign.center,
                      style: PanelText.body,
                    ),
                    const SizedBox(height: 24),
                    PanelCard(
                      child: Column(
                        children: <Widget>[
                          PanelFactRow(
                            icon: Icons.crop_free,
                            title: '截图快捷键：$shortcut',
                            detail: '按下即可框选屏幕区域。首次截图时系统会要求授予屏幕录制权限。',
                          ),
                          const PanelDivider(),
                          PanelFactRow(
                            icon: Icons.menu_open,
                            title: '$trayLocation的图标',
                            detail: '点它可以看到“立即截屏 / 设置 / 退出”。',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: onOpenSettings,
                          style: PanelButtons.primary,
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text('打开设置'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: onClose,
                          style: PanelButtons.secondary,
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
