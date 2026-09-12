import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 文字标注的**唯一**渲染规格。
///
/// 测量（输入框自动撑大）、浮层绘制、编辑框里的输入样式、导出 PNG 的绘制必须是
/// 同一份 TextStyle，否则「打字时看到的排版」和「导出的图片」会不一致。
/// `height: 1` 尤其重要：它决定了测量出来的行高。
TextStyle textAnnotationStyle(double fontSize, {Color? color}) {
  return TextStyle(color: color, fontSize: fontSize, height: 1);
}

/// 测量一段标注文字占多大。
///
/// 空文本按 `M` 量（输入框刚创建时的占位宽度），和绘制用的是同一个
/// [textAnnotationStyle]，因此测出来的尺寸一定够放。
Size measureAnnotationText(
  String text, {
  required double fontSize,
  required double maxWidth,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text.isEmpty ? 'M' : text,
      style: textAnnotationStyle(fontSize),
    ),
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: math.max(1, maxWidth));
  return Size(painter.width, painter.height);
}
