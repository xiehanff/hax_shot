import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

class CaptureToolbar extends StatefulWidget {
  const CaptureToolbar({
    required this.enabled,
    required this.busy,
    required this.onCancel,
    required this.onSave,
    required this.onCopy,
    super.key,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSave;
  final VoidCallback onCopy;

  @override
  State<CaptureToolbar> createState() => _CaptureToolbarState();
}

class _CaptureToolbarState extends State<CaptureToolbar> {
  Color _selectedColor = _ToolbarColorPalette.colors.first;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: 24,
            sigmaY: 24,
            tileMode: TileMode.clamp,
          ),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  ui.Color.fromARGB(255, 113, 72, 139),
                  ui.Color.fromARGB(255, 95, 58, 168),
                ],
              ),
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(997),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xF20D0D10), Color(0xFF000000)],
                    stops: [0, 0.55],
                  ),
                  borderRadius: BorderRadius.all(Radius.circular(997)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ToolbarIconButton(
                        icon: HugeIcons.strokeRoundedCancel01,
                        tooltip: '取消 (Esc)',
                        onPressed: widget.busy ? null : widget.onCancel,
                      ),
                      const _ToolbarDivider(),
                      _ToolbarIconButton(
                        icon: HugeIcons.strokeRoundedRectangular,
                        tooltip: '框选（当前工具）',
                        selected: true,
                        onPressed: null,
                      ),
                      _ToolbarIconButton(
                        icon: HugeIcons.strokeRoundedArrowDownLeft01,
                        tooltip: '标注箭头（即将支持）',
                        onPressed: null,
                      ),
                      _ToolbarIconButton(
                        icon: HugeIcons.strokeRoundedText,
                        tooltip: '标注文字（即将支持）',
                        onPressed: null,
                      ),
                      const _ToolbarDivider(),
                      _ToolbarColorPalette(
                        selectedColor: _selectedColor,
                        onSelected: (color) {
                          setState(() => _selectedColor = color);
                        },
                      ),
                      const _ToolbarDivider(),
                      const _AiPlaceholderGroup(),
                      const _ToolbarDivider(),
                      _ToolbarTextButton(
                        icon: HugeIcons.strokeRoundedSave,
                        tooltip: '保存 PNG',
                        onPressed: !widget.enabled || widget.busy
                            ? null
                            : widget.onSave,
                      ),
                      const SizedBox(width: 4),
                      _ToolbarTextButton(
                        icon: HugeIcons.strokeRoundedCopy01,
                        tooltip: '复制到剪贴板',
                        busy: widget.busy,
                        onPressed: !widget.enabled || widget.busy
                            ? null
                            : widget.onCopy,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final List<List<dynamic>> icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = selected || onPressed != null
        ? Colors.white
        : Colors.white.withValues(alpha: 0.48);

    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: HugeIcon(
        icon: icon,
        color: foregroundColor,
        size: 20,
        strokeWidth: 1.5,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      style: IconButton.styleFrom(
        foregroundColor: foregroundColor,
        disabledForegroundColor: foregroundColor,
        backgroundColor: selected
            ? Colors.white.withValues(alpha: 0.18)
            : Colors.transparent,
        overlayColor: Colors.white.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
    );
  }
}

class _ToolbarTextButton extends StatelessWidget {
  const _ToolbarTextButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });

  final List<List<dynamic>> icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = onPressed == null
        ? Colors.white.withValues(alpha: 0.48)
        : Colors.white;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : HugeIcon(
                      icon: icon,
                      color: foregroundColor,
                      size: 20,
                      strokeWidth: 1.5,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Colors.white.withValues(alpha: 0.32),
    );
  }
}

class _ToolbarColorPalette extends StatelessWidget {
  const _ToolbarColorPalette({
    required this.selectedColor,
    required this.onSelected,
  });

  static const colors = <Color>[
    Color(0xFFE53935), // red
    Color(0xFF8E44AD), // purple
    Color(0xFFFBC02D), // yellow
    Color(0xFF2E9B59), // green
    Color(0xFFF57C00), // orange
  ];

  final Color selectedColor;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '选择标注颜色',
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final color in colors)
              _ToolbarColorSwatch(
                color: color,
                selected: color == selectedColor,
                onTap: () => onSelected(color),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarColorSwatch extends StatelessWidget {
  const _ToolbarColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _colorName(color),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? color : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.86),
                  width: 0.8,
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  String _colorName(Color color) {
    if (color == _ToolbarColorPalette.colors[0]) return '红色';
    if (color == _ToolbarColorPalette.colors[1]) return '紫色';
    if (color == _ToolbarColorPalette.colors[2]) return '黄色';
    if (color == _ToolbarColorPalette.colors[3]) return '绿色';
    return '橙色';
  }
}

class _AiPlaceholderGroup extends StatelessWidget {
  const _AiPlaceholderGroup();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          _AiIcon(icon: HugeIcons.strokeRoundedAiChat02, tooltip: 'AI'),
          _AiIcon(icon: HugeIcons.strokeRoundedTranslate, tooltip: '翻译（即将支持）'),
          _AiIcon(
            icon: HugeIcons.strokeRoundedBookOpenCheck,
            tooltip: '解释（即将支持）',
          ),
          _AiIcon(
            icon: HugeIcons.strokeRoundedKnowledge01,
            tooltip: '深度理解（即将支持）',
          ),
        ],
      ),
    );
  }
}

class _AiIcon extends StatelessWidget {
  const _AiIcon({required this.icon, required this.tooltip});

  final List<List<dynamic>> icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 32,
        height: 40,
        child: Center(
          child: HugeIcon(
            icon: icon,
            color: Colors.white,
            size: 18,
            strokeWidth: 1.5,
          ),
        ),
      ),
    );
  }
}
