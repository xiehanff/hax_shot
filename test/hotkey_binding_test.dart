import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/settings/hotkey_binding.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  if (Platform.isMacOS) _carbonKeyCodeTests();

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

/// `macosCarbonKeyCode` 是注册路径唯一的键码来源。它必须和以前
/// `hotkey_manager` 发过去的 Carbon 键码一致——那个值就是 Flutter 公开常量表
/// `kMacOsToPhysicalKey` 的 key，所以这里直接钉住具体数值：表变了这条就会红。
///
/// 只在本机 macOS 上跑：`HotKey.physicalKey` 是**按平台分发**的映射，
/// Linux CI 上会走 GTK 那张表，推出来的键码没有意义。
void _carbonKeyCodeTests() {
  test('Carbon 虚拟键码取自 kMacOsToPhysicalKey，不是 USB HID usage', () {
    // USB HID 的 Z 是 0x1d(29)，Carbon 的 kVK_ANSI_Z 是 6：发错这一位就是
    // “注册成功了但按下去没反应”。
    expect(macosCarbonKeyCode('<Alt><Shift>z'), 6);
    expect(macosCarbonKeyCode('<Alt>space'), 49);
    expect(macosCarbonKeyCode('<Alt>Return'), 36);
    expect(macosCarbonKeyCode('<Alt>Tab'), 48);
    expect(macosCarbonKeyCode('<Alt>BackSpace'), 51);
    expect(macosCarbonKeyCode('<Control><Alt>Delete'), 117);
    expect(macosCarbonKeyCode('<Alt>F1'), 122);
    expect(macosCarbonKeyCode('<Alt>F5'), 96);
    expect(macosCarbonKeyCode('<Alt>F12'), 111);
    expect(macosCarbonKeyCode('<Alt>Up'), 126);
    expect(macosCarbonKeyCode('<Alt>Down'), 125);
    expect(macosCarbonKeyCode('<Alt>Left'), 123);
    expect(macosCarbonKeyCode('<Alt>Right'), 124);
    expect(macosCarbonKeyCode('<Control><Shift>1'), 18);
    // 符号键：token 就是设置页产出的单字符（不是 'slash' 这种名字）。
    expect(macosCarbonKeyCode('<Alt>/'), 44);
    expect(macosCarbonKeyCode('<Alt>;'), 41);
    expect(macosCarbonKeyCode('<Alt>,'), 43);
    expect(macosCarbonKeyCode('<Alt>.'), 47);
    expect(macosCarbonKeyCode('<Alt>-'), 27);
    expect(macosCarbonKeyCode('<Alt>='), 24);
    expect(macosCarbonKeyCode('<Alt>['), 33);
    expect(macosCarbonKeyCode('<Alt>]'), 30);
    expect(macosCarbonKeyCode('<Alt>\''), 39);
  });

  test('设置页能录出来的按键都有 Carbon 键码', () {
    for (final binding in <String>[
      '<Alt><Shift>z',
      '<Super><Shift>z',
      '<Control><Alt>Delete',
      '<Alt>Page_Up',
      '<Alt>Page_Down',
      '<Alt>Home',
      '<Alt>End',
      for (var index = 1; index <= 20; index++) '<Alt>F$index',
      for (final letter in 'abcdefghijklmnopqrstuvwxyz'.split(''))
        '<Alt>$letter',
      for (var digit = 0; digit <= 9; digit++) '<Alt>$digit',
      for (final symbol in <String>[
        '/',
        ';',
        ',',
        '.',
        '-',
        '=',
        '[',
        ']',
        "'",
      ])
        '<Alt>$symbol',
    ]) {
      expect(macosCarbonKeyCode(binding), isNotNull, reason: binding);
    }
  });

  test('macOS 没有的键返回 null，调用方必须当成注册失败', () {
    // Flutter 有 F24，但 kMacOsToPhysicalKey 里没有对应项。
    expect(macosCarbonKeyCode('<Alt>F24'), isNull);
  });
}
