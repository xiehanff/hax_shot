import 'dart:io';

import 'package:flutter/material.dart';
import '../window/rounded_window.dart';

/// 首次启动的欢迎页。
///
/// 托盘/菜单栏应用没有 Dock 图标，双击启动后屏幕上不会出现任何东西，新用户会以为
/// 没启动。这一页把三件事说清楚：图标在哪、快捷键是什么、第一次截图会要权限。
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
    final theme = Theme.of(context);
    final trayLocation = Platform.isMacOS ? '菜单栏右侧' : '系统托盘';
    final shortcut = shortcutLabel.isEmpty ? '未设置' : shortcutLabel;

    return RoundedWindow(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Hax Shot 已启动'),
          actions: [
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.celebration_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text('Hax Shot 已在后台运行', style: theme.textTheme.titleLarge),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '它没有主窗口，启动后只在$trayLocation显示一个小图标，'
                  '所有操作都从那个图标开始；想改快捷键或开机自启动，打开设置页即可。',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                _Fact(
                  icon: Icons.crop_free,
                  title: '截图快捷键：$shortcut',
                  detail: '按下即可框选屏幕区域。首次截图时系统会要求授予屏幕录制权限。',
                ),
                const SizedBox(height: 10),
                _Fact(
                  icon: Icons.menu_open,
                  title: '$trayLocation的图标',
                  detail: '点它可以看到“立即截屏 / 设置 / 退出”。',
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: onOpenSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('打开设置'),
                    ),
                    OutlinedButton(
                      onPressed: onClose,
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
