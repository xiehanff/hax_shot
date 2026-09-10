import 'package:flutter/material.dart';

/// 品牌色：图标里的亮姜黄（`assets/icons/hax_shot_source.png` 主色 #F8C800）。
///
/// 只用在这种“要用户动手”的页面上（授权引导、设置页）：深色主题默认的浅蓝按钮
/// 和图标风格不一致。
const Color haxAccent = Color(0xFFF8C800);

/// 深色背景上用姜黄做前景时，按钮里的文字/图标要压暗才看得清。
const Color _onHaxAccent = Color(0xFF1F1800);

/// 把品牌色套到一个页面。
///
/// 规则很简单：**只有实心按钮（`FilledButton`）是姜黄**，其他文字一律中性色。
///
/// - 只给 `FilledButton` 设 backgroundColor / foregroundColor，绝不覆盖 `colorScheme`：
///   覆盖 `colorScheme.primary` 会连带把 `OutlinedButton` / `TextButton` 的标签和任何
///   用 `primary` 的图标染色（先是琥珀、去掉覆盖后又变成主题的浅蓝）；
/// - `OutlinedButton` / `TextButton` 的标签显式用 `onSurface`（和页面正文同一个白），
///   不要主题的 primary，否则又是蓝字。
ThemeData haxAccentTheme(ThemeData base) {
  final labelColor = base.colorScheme.onSurface;
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: haxAccent,
        foregroundColor: _onHaxAccent,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: labelColor),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: labelColor),
    ),
  );
}
