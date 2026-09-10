import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../hax_colors.dart';
import '../window/rounded_window.dart';
import 'package:window_manager/window_manager.dart';

/// 没有屏幕录制权限时的引导页。
///
/// 刻意做成普通页面而不是全屏浮层：用户可能还没授权，这时候必须能看清引导、
/// 能直接跳到系统设置，也能随手关掉，而不是被一块盖住整个屏幕的黑屏困住。
class CapturePermissionGuide extends StatefulWidget {
  const CapturePermissionGuide({
    required this.onRetry,
    required this.onQuit,
    this.onResetPermission,
    this.message,
    super.key,
  });

  /// “我已授权，重新检查”，返回后由调用方重新尝试抓屏。
  final Future<void> Function() onRetry;

  /// 关闭捕获进程。
  final VoidCallback onQuit;

  /// 重置系统的屏幕录制授权记录（macOS 专用）；null 表示当前平台没有这个动作。
  ///
  /// 用于“系统设置里开关是开的，但当前进程就是没权限、也不再弹授权框”这种
  /// 签名指纹变化导致的死结。
  final Future<void> Function()? onResetPermission;

  /// 其它失败原因（非权限问题）时显示的说明。
  final String? message;

  /// macOS 的屏幕录制设置面板。
  static final screenRecordingSettings = Uri.parse(
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  );

  @override
  State<CapturePermissionGuide> createState() => _CapturePermissionGuideState();
}

class _CapturePermissionGuideState extends State<CapturePermissionGuide> {
  bool _checking = false;
  bool _resetting = false;
  String? _hint;

  Future<void> _openSettings() async {
    try {
      await launchUrl(CapturePermissionGuide.screenRecordingSettings);
      if (!mounted) return;
      setState(() => _hint = '已打开系统设置，勾选 Hax Shot 后回来点下面的按钮。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _hint = '打不开系统设置：$error\n请手动打开“系统设置 → 隐私与安全性 → 屏幕录制”。');
    }
  }

  Future<void> _retry() async {
    setState(() {
      _checking = true;
      _hint = null;
    });
    await widget.onRetry();
    if (!mounted) return;
    setState(() => _checking = false);
  }

  Future<void> _resetPermission() async {
    final reset = widget.onResetPermission;
    if (reset == null) return;
    setState(() {
      _resetting = true;
      _hint = '正在清掉旧的授权记录…';
    });
    try {
      await reset();
      if (!mounted) return;
      setState(() => _hint = '已清掉旧的授权记录，接下来会重新弹出系统授权请求。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _hint = '重置授权记录失败：$error');
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Esc 也能关掉：窗口没有原生标题栏，键盘是最可靠的一个出口。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onQuit,
      },
      child: Focus(autofocus: true, child: _buildScaffold(theme)),
    );
  }

  Widget _buildScaffold(ThemeData theme) {
    // 只有按钮用图标同款的亮姜黄（见 lib/hax_colors.dart）；图标和文字保持中性色。
    final accented = haxAccentTheme(theme);
    return Theme(
      data: accented,
      child: RoundedWindow(
        child: Scaffold(
          // 内容顶部对齐：窗口本身不高，垂直居中会把标题行（以及右上角的 ✕）推到
          // 窗口中间，看起来就不在右上角了。
          body: Align(
            alignment: Alignment.topLeft,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题行：只有左侧这块是拖拽区（窗口没有原生标题栏），
                  // 右上角的关闭按钮必须留在拖拽区之外，否则点击会被拖拽手势吞掉。
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => windowManager.startDragging(),
                          child: Row(
                            children: [
                              Icon(
                                Icons.screen_lock_portrait_outlined,
                                color: theme.colorScheme.onSurface,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '需要屏幕录制权限',
                                style: theme.textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: widget.onQuit,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Hax Shot 只在你按下快捷键（或点“立即截屏”）时抓一次屏，不会录屏，'
                    '也不会把画面传到别处。macOS 要求在“系统设置”里手动授权。',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '1. 点下面“打开系统设置”',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '2. 在“隐私与安全性 → 屏幕录制”里勾选 Hax Shot',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '3. 回到这里点“我已授权，重新检查”（会自动重启抓屏进程，'
                            'macOS 的授权要新进程才生效）',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 开发期的坑：从终端 / `flutter run` 启动时，屏幕录制授权会记在终端
                  // 身上，Hax Shot 不会出现在系统设置列表里（macOS 15 的该面板也不能
                  // 手动“+”添加），于是用户怎么都授权不了。
                  if (Platform.isMacOS) ...[
                    const SizedBox(height: 14),
                    Text(
                      '如果你是从终端或 flutter run 启动的：授权会记在终端上，'
                      'Hax Shot 不会出现在列表里。请改用 Finder 双击（或 open）'
                      'build 目录里的 .app，再从它里面点“打开系统设置”。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (widget.message != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      widget.message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  if (_hint != null) ...[
                    const SizedBox(height: 16),
                    Text(_hint!, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('打开系统设置'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _checking ? null : _retry,
                        icon: _checking
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text('我已授权，重新检查'),
                      ),
                      // 只在 macOS 出现：清掉因签名指纹变化而失效的旧授权记录。
                      if (widget.onResetPermission != null)
                        TextButton.icon(
                          onPressed: _resetting ? null : _resetPermission,
                          icon: _resetting
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.settings_backup_restore,
                                  size: 18,
                                ),
                          label: const Text('重置授权记录'),
                        ),
                    ],
                  ),
                  if (widget.onResetPermission != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '“重置授权记录”用于：系统设置里开关是开的，但当前进程就是没权限、'
                      '也不再弹授权框（本地 ad-hoc 签名每次构建指纹都会变，旧记录就对不上了）。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
