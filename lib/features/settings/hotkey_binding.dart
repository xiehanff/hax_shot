import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// 把设置页产出的跨平台绑定字符串（例如 `<Alt><Shift>z`）转成 `hotkey_manager` 的 `HotKey`。
///
/// 绑定字符串在 Linux(gsettings) 和 macOS 之间共用，因此这里支持的是两边都能
/// 表达的一套 token；不支持时返回 null，由调用方给出可读的提示。
///
/// token 规则（由 `shortcut_settings_page.dart` 的 `_bindingKeyName` 产出）：
/// - 修饰键：`<Control>` `<Alt>` `<Shift>` `<Super>`（macOS 上 Super 即 Command）
/// - 按键：单个字母/数字、符号、`space` `Return` `Tab` `BackSpace` `Delete`
///   `Insert` `Home` `End` `Page_Up` `Page_Down` `Up` `Down` `Left` `Right`、`F1`..`F35`
HotKey? hotKeyFromBinding(
  String binding, {
  String identifier = 'hax_shot.capture',
}) {
  final modifiers = <HotKeyModifier>[];
  var rest = binding.trim();
  if (rest.isEmpty) return null;

  while (rest.startsWith('<')) {
    final end = rest.indexOf('>');
    if (end < 0) return null;
    final name = rest.substring(1, end).toLowerCase();
    rest = rest.substring(end + 1);
    switch (name) {
      case 'control' || 'ctrl':
        modifiers.add(HotKeyModifier.control);
      case 'alt' || 'option':
        modifiers.add(HotKeyModifier.alt);
      case 'shift':
        modifiers.add(HotKeyModifier.shift);
      case 'super' || 'meta' || 'command' || 'cmd':
        modifiers.add(HotKeyModifier.meta);
      default:
        return null;
    }
  }

  final key = logicalKeyFromBindingToken(rest);
  if (key == null || modifiers.isEmpty) return null;
  return HotKey(
    identifier: identifier,
    key: key,
    modifiers: modifiers,
    scope: HotKeyScope.system,
  );
}

/// 绑定字符串 → macOS Carbon 虚拟键码（`kVK_*`）。
///
/// 为什么要单独算：`macos/Runner/ShortcutBridge.swift` 直接调
/// `RegisterEventHotKey`，它要的是 Carbon 虚拟键码，**不是** USB HID usage。
/// 以前 `hotkey_manager` 也是把 Carbon 键码发过去的（它内部用 Flutter 公开的
/// `kMacOsToPhysicalKey` 把 Carbon 键码映射成 `PhysicalKeyboardKey`），所以这里
/// 反过来用同一张表：先从绑定拿到 `PhysicalKeyboardKey`，再按 usbHidUsage 找回
/// Carbon 键码。
///
/// 返回 null 表示这个按键在 macOS 上没有对应的 Carbon 键码（Flutter 有、macOS 没定义，
/// 例如 F21+）：调用方必须把它当“注册失败”，不能静默跳过。
int? macosCarbonKeyCode(String binding) {
  final hotKey = hotKeyFromBinding(binding);
  return hotKey == null ? null : carbonKeyCodeFromHotKey(hotKey);
}

/// 同上，但直接吃一个已经解析好的 [HotKey]（注册路径用的是这个）。
int? carbonKeyCodeFromHotKey(HotKey hotKey) {
  final PhysicalKeyboardKey physical;
  try {
    physical = hotKey.physicalKey;
  } on Object {
    // hotkey_manager 的 physicalKey 是强解包，没有物理键映射时会抛。
    return null;
  }
  for (final MapEntry<int, PhysicalKeyboardKey> entry
      in kMacOsToPhysicalKey.entries) {
    if (entry.value.usbHidUsage == physical.usbHidUsage) return entry.key;
  }
  return null;
}

/// [HotKey] 的修饰键 → 原生桥认识的字符串（`alt` / `control` / `shift` / `meta`）。
List<String> modifierNamesFromHotKey(HotKey hotKey) => <String>[
  for (final HotKeyModifier modifier
      in hotKey.modifiers ?? const <HotKeyModifier>[])
    switch (modifier) {
      HotKeyModifier.alt => 'alt',
      HotKeyModifier.control => 'control',
      HotKeyModifier.shift => 'shift',
      HotKeyModifier.meta => 'meta',
      HotKeyModifier.capsLock => 'capsLock',
      HotKeyModifier.fn => 'fn',
    },
];

/// 绑定字符串里的按键 token → `LogicalKeyboardKey`。
LogicalKeyboardKey? logicalKeyFromBindingToken(String token) {
  final lower = token.toLowerCase();
  if (lower.length == 1) {
    final code = lower.codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) {
      return _letters[code - 0x61];
    }
    if (code >= 0x30 && code <= 0x39) {
      return _digits[code - 0x30];
    }
    return _symbols[lower];
  }

  final named = _namedKeys[lower];
  if (named != null) return named;

  final functionIndex = int.tryParse(
    lower.startsWith('f') ? lower.substring(1) : '',
  );
  if (functionIndex != null &&
      functionIndex >= 1 &&
      functionIndex <= _functions.length) {
    return _functions[functionIndex - 1];
  }
  return null;
}

const _letters = <LogicalKeyboardKey>[
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyF,
  LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.keyH,
  LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyN,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyP,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyS,
  LogicalKeyboardKey.keyT,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyY,
  LogicalKeyboardKey.keyZ,
];

const _digits = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

const _symbols = <String, LogicalKeyboardKey>{
  '-': LogicalKeyboardKey.minus,
  '=': LogicalKeyboardKey.equal,
  '[': LogicalKeyboardKey.bracketLeft,
  ']': LogicalKeyboardKey.bracketRight,
  r'\': LogicalKeyboardKey.backslash,
  ';': LogicalKeyboardKey.semicolon,
  "'": LogicalKeyboardKey.quote,
  ',': LogicalKeyboardKey.comma,
  '.': LogicalKeyboardKey.period,
  '/': LogicalKeyboardKey.slash,
  '`': LogicalKeyboardKey.backquote,
};

const _namedKeys = <String, LogicalKeyboardKey>{
  'space': LogicalKeyboardKey.space,
  'return': LogicalKeyboardKey.enter,
  'enter': LogicalKeyboardKey.enter,
  'tab': LogicalKeyboardKey.tab,
  'backspace': LogicalKeyboardKey.backspace,
  'delete': LogicalKeyboardKey.delete,
  'insert': LogicalKeyboardKey.insert,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'page_up': LogicalKeyboardKey.pageUp,
  'page_down': LogicalKeyboardKey.pageDown,
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
};

/// F1..F24：Flutter 只定义了这些功能键。
const _functions = <LogicalKeyboardKey>[
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
  LogicalKeyboardKey.f13,
  LogicalKeyboardKey.f14,
  LogicalKeyboardKey.f15,
  LogicalKeyboardKey.f16,
  LogicalKeyboardKey.f17,
  LogicalKeyboardKey.f18,
  LogicalKeyboardKey.f19,
  LogicalKeyboardKey.f20,
  LogicalKeyboardKey.f21,
  LogicalKeyboardKey.f22,
  LogicalKeyboardKey.f23,
  LogicalKeyboardKey.f24,
];
