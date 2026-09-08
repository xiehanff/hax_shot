import 'package:flutter/material.dart';

abstract final class HaxAiColors {
  static const scaffoldBg = Color(0xFF121318);
  static const surfaceBg = Color(0xFF1D2028);
  static const fieldBg = Color(0xFF17191F);
  static const fillSubtle = Color(0xFF242832);
  static const accentSurface = Color(0xFF394C82);
  static const accentBright = Color(0xFF98B8FF);
  static const borderSoft = Color(0xFF343A46);
  static const borderVisible = Color(0xFF4B5362);
  static const borderFocused = Color(0xFF7898DD);
  static const textPrimary = Color(0xFFF2F4F7);
  static const textSecondary = Color(0xFFB8C0CC);
  static const textTertiary = Color(0xFF8B93A1);
  static const textHint = Color(0xFF707887);
}

// Keeps the copied Plume widget styling readable while using HaxShot colors.
typedef AppColors = HaxAiColors;
