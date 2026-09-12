import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../hax_colors.dart';

/// 托盘宿主 / 捕获进程里这些“临时小窗口”（欢迎页、授权引导）共用的视觉语言。
///
/// 风格目标：简洁。一块底色 + 一张描边圆角卡片 + 一个强调按钮，靠留白、细描边和
/// 灰蓝点缀分层，不用重阴影和渐变。强调色取 `haxAccent`（灰蓝），和应用主题一致。
///
/// **源头是 `lib/hax_colors.dart`**：`accent` / `accentText` / `title` 直接引用那里的
/// 常量，半透明的 `accentSoft` / `accentBorder` 由 `haxAccent` 加透明度派生。这些值
/// AI 面板（`ai_colors.dart`）也在用，所以只定义一次、两边引用，而不是各抄一份
/// 16 进制字面量。反向引用不可取：本文件依赖 `window_manager`，被 AI 面板引用会把
/// 窗口插件拖进那边的 import 图。
abstract final class PanelColors {
  /// 窗口底色，比卡片暗一档。
  static const bg = Color(0xFF101418);

  /// 卡片 / 内容块底色。
  static const card = Color(0xFF171C22);

  /// 卡片描边。
  static const cardBorder = Color(0xFF232A33);

  /// 1px 分割线（比卡片描边更弱）。
  static const hairline = Color(0xFF1E242C);

  static const title = haxTextPrimary;
  static const body = Color(0xFFA8B1BD);
  static const muted = Color(0xFF7C8794);

  /// 强调色：灰蓝，直接引用 `hax_colors.dart` 的源头常量。
  static const accent = haxAccent;

  /// 强调色的浅底（图标徽标、提示条）。由 `haxAccent` 加透明度派生：
  /// `0x1F / 255` 折算后与原字面量 `Color(0x1F8FAEC9)` 完全等值。
  static final accentSoft = haxAccent.withValues(alpha: 0x1F / 255);

  /// 强调色在深底上的文字/图标版本（引用 `hax_colors.dart` 的源头常量）。
  static const accentText = haxAccentBright;

  /// 强调色的浅描边，同样从 `haxAccent` 派生（`0x33 / 255 = 0.2`，
  /// 等价于原字面量 `Color(0x338FAEC9)`）。
  static final accentBorder = haxAccent.withValues(alpha: 0x33 / 255);

  static const hover = Color(0x14FFFFFF);
  static const danger = Color(0xFFFF9A8F);
  static const dangerSoft = Color(0x1AFF9A8F);
  static const dangerBorder = Color(0x33FF9A8F);
}

/// 面板里的文字样式，避免每个页面各写一套字号。
abstract final class PanelText {
  static const headerTitle = TextStyle(
    color: PanelColors.title,
    fontSize: 16.5,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  /// 居中大标题（欢迎页那种“徽标 + 标题 + 说明”的开场版式）。
  static const heroTitle = TextStyle(
    color: PanelColors.title,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.25,
    letterSpacing: -0.2,
  );

  static const body = TextStyle(
    color: PanelColors.body,
    fontSize: 12.5,
    height: 1.6,
  );

  static const factTitle = TextStyle(
    color: PanelColors.title,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  static const factDetail = TextStyle(
    color: PanelColors.muted,
    fontSize: 11.5,
    height: 1.55,
  );

  static const note = TextStyle(
    color: PanelColors.muted,
    fontSize: 11.5,
    height: 1.55,
  );
}

/// 按钮样式：一个灰蓝实心主操作，其余是描边 / 纯文字，统一 10px 圆角。
abstract final class PanelButtons {
  static final primary = FilledButton.styleFrom(
    backgroundColor: PanelColors.accent,
    foregroundColor: const Color(0xFF101A24),
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
  );

  static final secondary = OutlinedButton.styleFrom(
    foregroundColor: PanelColors.title,
    backgroundColor: PanelColors.card,
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    side: const BorderSide(color: PanelColors.cardBorder),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
  );

  static final ghost = TextButton.styleFrom(
    foregroundColor: PanelColors.muted,
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
  );
}

/// 面板顶部条：整条可拖动（窗口没有原生标题栏）。
///
/// 传了 [icon] / [title] 就是“徽标 + 标题”的常规头部（授权引导用）；都不传就只留
/// 拖拽区 + 关闭按钮（欢迎页用居中大标题开场）。
///
/// 顶部条必须铺满可拖区，但文字会吃掉 hit test，所以左边那块套 `IgnorePointer`，
/// 只留关闭按钮可点。
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    required this.onClose,
    this.icon,
    this.title,
    this.closeTooltip = '关闭',
    this.height = 68,
    super.key,
  });

  final IconData? icon;
  final String? title;
  final VoidCallback onClose;
  final String closeTooltip;
  final double height;

  @override
  Widget build(BuildContext context) {
    final IconData? badgeIcon = icon;
    final String? headerTitle = title;
    // 用 `Positioned.fill` 包住内容行：Stack 的非定位子节点是**顶部对齐**的，
    // 直接塞一个 Row 进去，它只会按自身高度（徽标/关闭按钮那么高）贴在窗口顶边，
    // 顶部留白变成 0 —— 这就是“标题贴着窗口”的成因。`Positioned.fill` 把行撑到
    // header 的全高，由 Row 自己的 crossAxisAlignment.center 做垂直居中。
    return SizedBox(
      height: height,
      child: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: IgnorePointer(
                      child: Row(
                        children: <Widget>[
                          if (badgeIcon != null) ...<Widget>[
                            PanelIconBadge(icon: badgeIcon),
                            const SizedBox(width: 10),
                          ],
                          if (headerTitle != null)
                            Flexible(
                              child: Text(
                                headerTitle,
                                overflow: TextOverflow.ellipsis,
                                style: PanelText.headerTitle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  PanelCloseButton(tooltip: closeTooltip, onPressed: onClose),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆角方形图标底，强调色浅底 + 细描边。
class PanelIconBadge extends StatelessWidget {
  const PanelIconBadge({
    required this.icon,
    this.size = 34,
    this.iconSize = 17,
    super.key,
  });

  final IconData icon;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: PanelColors.accentSoft,
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: PanelColors.accentBorder),
      ),
      child: Icon(icon, size: iconSize, color: PanelColors.accentText),
    );
  }
}

class PanelCloseButton extends StatefulWidget {
  const PanelCloseButton({
    required this.onPressed,
    this.tooltip = '关闭',
    super.key,
  });

  final VoidCallback onPressed;
  final String tooltip;

  @override
  State<PanelCloseButton> createState() => _PanelCloseButtonState();
}

class _PanelCloseButtonState extends State<PanelCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hovered ? PanelColors.hover : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close,
              size: 16,
              color: _hovered ? PanelColors.title : PanelColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 描边圆角卡片。
class PanelCard extends StatelessWidget {
  const PanelCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: PanelColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PanelColors.cardBorder),
      ),
      child: child,
    );
  }
}

/// 卡片里的 1px 分割线。
class PanelDivider extends StatelessWidget {
  const PanelDivider({this.vertical = 12, super.key});

  final double vertical;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: const SizedBox(
        height: 1,
        child: ColoredBox(color: PanelColors.hairline),
      ),
    );
  }
}

/// 图标 + 标题 + 说明的一行，用在卡片里。
class PanelFactRow extends StatelessWidget {
  const PanelFactRow({
    required this.icon,
    required this.title,
    required this.detail,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PanelIconBadge(icon: icon, size: 30, iconSize: 15),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: PanelText.factTitle),
              const SizedBox(height: 3),
              Text(detail, style: PanelText.factDetail),
            ],
          ),
        ),
      ],
    );
  }
}

enum PanelNoteTone { muted, accent, danger }

/// 浅底提示条：终端启动说明、状态提示、错误信息都用它，靠底色区分语气。
class PanelNote extends StatelessWidget {
  const PanelNote({
    required this.text,
    this.icon,
    this.tone = PanelNoteTone.muted,
    super.key,
  });

  final String text;
  final IconData? icon;
  final PanelNoteTone tone;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color border, Color foreground) = switch (tone) {
      PanelNoteTone.accent => (
        PanelColors.accentSoft,
        PanelColors.accentBorder,
        PanelColors.accentText,
      ),
      PanelNoteTone.danger => (
        PanelColors.dangerSoft,
        PanelColors.dangerBorder,
        PanelColors.danger,
      ),
      PanelNoteTone.muted => (
        const Color(0x0DFFFFFF),
        const Color(0x17FFFFFF),
        PanelColors.muted,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 14, color: foreground),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style: PanelText.note.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
