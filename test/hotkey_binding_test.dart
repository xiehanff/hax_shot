import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/settings/hotkey_binding.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  test('把共用绑定字符串转成 hotkey_manager 的 HotKey', () {
    final alt = hotKeyFromBinding('<Alt>z');
    expect(alt, isNotNull);
    expect(alt!.key, LogicalKeyboardKey.keyZ);
    expect(alt.modifiers, contains(HotKeyModifier.alt));
    expect(alt.scope, HotKeyScope.system);

    // macOS 上 Super 就是 Command。
    final cmd = hotKeyFromBinding('<Super><Shift>z');
    expect(cmd!.key, LogicalKeyboardKey.keyZ);
    expect(
      cmd.modifiers,
      containsAll([HotKeyModifier.meta, HotKeyModifier.shift]),
    );
  });

  test('支持设置页能录出的命名键与功能键', () {
    expect(hotKeyFromBinding('<Alt>space')!.key, LogicalKeyboardKey.space);
    expect(
      hotKeyFromBinding('<Control><Alt>Delete')!.key,
      LogicalKeyboardKey.delete,
    );
    expect(hotKeyFromBinding('<Alt>Return')!.key, LogicalKeyboardKey.enter);
    expect(hotKeyFromBinding('<Alt>Page_Up')!.key, LogicalKeyboardKey.pageUp);
    expect(hotKeyFromBinding('<Alt>F13')!.key, LogicalKeyboardKey.f13);
    expect(hotKeyFromBinding('<Alt>F24')!.key, LogicalKeyboardKey.f24);
    expect(hotKeyFromBinding('<Alt>,')!.key, LogicalKeyboardKey.comma);
    expect(hotKeyFromBinding('<Alt>7')!.key, LogicalKeyboardKey.digit7);
  });

  test('无法表达的组合返回 null，由调用方给出可读提示', () {
    // 没有修饰键
    expect(hotKeyFromBinding('z'), isNull);
    // 不认识的修饰键
    expect(hotKeyFromBinding('<Hyper>z'), isNull);
    // 设置页的兜底 token（例如 Caps_Lock）目前无法映射
    expect(hotKeyFromBinding('<Alt>Caps_Lock'), isNull);
    // Flutter 只定义到 F24
    expect(hotKeyFromBinding('<Alt>F25'), isNull);
    expect(hotKeyFromBinding(''), isNull);
    expect(hotKeyFromBinding('<Alt>'), isNull);
  });
}
