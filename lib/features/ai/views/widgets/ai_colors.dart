import 'package:flutter/material.dart';

import '../../../../hax_colors.dart';

/// AI 面板调色板。
///
/// **源头是 `lib/hax_colors.dart`**：`textPrimary`(#F2F4F7) 与 `accentBright`(#9DBBD6)
/// 跟托盘小窗口的 `PanelColors.title` / `PanelColors.accentText` 是同一批值，两套
/// 调色板都从这里引用同一个常量，而不是各存一份 16 进制字面量——两边的深色底本来
/// 就同源，抄两份只会在改色时漂移。
///
/// 为什么源头放 `hax_colors.dart` 而不是让两边互相引用：`panel_chrome.dart` 依赖
/// `window_manager`，反向引用会把窗口插件拖进 AI 面板的 import 图；`hax_colors.dart`
/// 只依赖 material，且本来就是应用主题色的定义处。
///
/// 本文件只保留 AI 面板真正独有的值（`scaffoldBg` / `titleBarBg` / 各类表面与描边）。
abstract final class HaxAiColors {
  static const scaffoldBg = Color(0xFF121318);

  /// AI 面板顶部条：比 scaffoldBg 略暗，用来和消息区区分（不放标题文字）。
  static const titleBarBg = Color(0xFF0C0D11);
  static const surfaceBg = Color(0xFF1D2028);
  static const fieldBg = Color(0xFF17191F);
  static const fillSubtle = Color(0xFF242832);
  // 主题色统一灰蓝（原来是偏紫的靛蓝 #394C82 / #98B8FF / #7898DD）。
  static const accentSurface = Color(0xFF3A5670);
  static const accentBright = haxAccentBright;
  static const borderSoft = Color(0xFF343A46);
  static const borderVisible = Color(0xFF4B5362);
  static const borderFocused = Color(0xFF7FA0BE);
  static const textPrimary = haxTextPrimary;
  static const textSecondary = Color(0xFFB8C0CC);
  static const textTertiary = Color(0xFF8B93A1);
  static const textHint = Color(0xFF707887);
}

// Keeps the copied Plume widget styling readable while using HaxShot colors.
typedef AppColors = HaxAiColors;
