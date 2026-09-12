import 'package:flutter/material.dart';

/// 主题色：灰蓝。
///
/// 图标（`assets/icons/hax_shot_source.png`，主色 `#7387A6`）和 app 内主题统一灰蓝；
/// 以前是亮姜黄 `#F8C800`，现在 app 内一律不用姜黄。
/// `#8FAEC9` 比图标主色亮一档：深色底上做按钮底色要亮一点对比度才够。
const Color haxAccent = Color(0xFF8FAEC9);

/// 灰蓝底色上用深色前景才看得清（和原来姜黄配深色文字同一个思路）。
const Color _onHaxAccent = Color(0xFF101A24);

/// 深色底上的主文字色 `#F2F4F7`。
///
/// **全应用只有这一份定义**：托盘小窗口的 `PanelColors.title`
/// 和 AI 面板的 `HaxAiColors.textPrimary` 都引用它。两处本来就是同一个深色底
/// 观感，各存一份 16 进制字面量只会在改色时互相漂移。
const Color haxTextPrimary = Color(0xFFF2F4F7);

/// 强调色在深色底上的文字 / 图标版本 `#9DBBD6`（比 [haxAccent] 更亮一档）。
///
/// 同样只有这一份：`PanelColors.accentText` 与 `HaxAiColors.accentBright` 都引用它。
const Color haxAccentBright = Color(0xFF9DBBD6);

/// [haxAccent] 压暗一档的灰蓝，给需要「亮 → 暗」灰蓝渐变的收暗端用
/// （例如截图工具栏那圈 2px 玻璃边：原来是紫 `#71488B` → 靛 `#5F3AA8`）。
const Color haxAccentDeep = Color(0xFF5B7C99);

/// 把主题色套到一个页面。
///
/// 规则很简单：**只有实心按钮（`FilledButton`）是灰蓝**，其他文字一律中性色。
///
/// - 只给 `FilledButton` 设 backgroundColor / foregroundColor，绝不覆盖 `colorScheme`：
///   覆盖 `colorScheme.primary` 会连带把 `OutlinedButton` / `TextButton` 的标签和任何
///   用 `primary` 的图标染色；
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
