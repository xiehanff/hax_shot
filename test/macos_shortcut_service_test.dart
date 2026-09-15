import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/diagnostics/diagnostic_log.dart';
import 'package:hax_shot/features/settings/macos_shortcut_service.dart';
import 'package:hax_shot/features/settings/shortcut_registration.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory logDirectory;
  late List<String> registeredBindings;
  late List<String> unregisteredBindings;

  setUp(() {
    logDirectory = Directory.systemTemp.createTempSync(
      'hax_shot_shortcut_test',
    );
    registeredBindings = <String>[];
    unregisteredBindings = <String>[];
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    try {
      logDirectory.deleteSync(recursive: true);
    } on Object {
      // 忽略清理失败。
    }
  });

  /// 用注入的假注册器构造服务；`failFor` 里的绑定会在注册时抛异常，
  /// `failUnregisterFor` 里的绑定会在注销时抛异常。
  MacosShortcutService build({
    Set<String> failFor = const <String>{},
    Set<String> failUnregisterFor = const <String>{},
  }) {
    return MacosShortcutService(
      log: DiagnosticLogService(directory: logDirectory),
      retryDelay: Duration.zero,
      registerHotKey: (HotKey hotKey, void Function() onTriggered) async {
        final binding = '${hotKey.modifiers?.length ?? 0}:${hotKey.identifier}';
        if (failFor.contains(_bindingOf(hotKey))) {
          throw StateError('注册被测试拒绝');
        }
        registeredBindings.add(binding);
      },
      unregisterHotKey: (HotKey hotKey) async {
        if (failUnregisterFor.contains(_bindingOf(hotKey))) {
          throw StateError('注销被测试拒绝');
        }
        unregisteredBindings.add(hotKey.identifier);
      },
    );
  }

  test('注册成功后状态是 active 并记住绑定', () async {
    final service = build();
    final result = await service.activate(onTriggered: () {});
    expect(result, isA<ShortcutActivationSuccess>());
    expect(service.status, ShortcutRegistrationStatus.active);
    expect(service.activeBinding, MacosShortcutService.defaultBinding);
    expect(service.lastError, isNull);
    expect(service.lastRegisteredAt, isNotNull);
    expect(registeredBindings, hasLength(1));
  });

  test('注册一直失败时状态是 failed 且不再静默', () async {
    final service = build(failFor: {MacosShortcutService.defaultBinding});
    final result = await service.activate(onTriggered: () {});
    expect(result, isA<ShortcutActivationFailure>());
    expect(service.status, ShortcutRegistrationStatus.failed);
    expect(service.activeBinding, isNull);
    expect(service.lastError, isNotNull);
  });

  test('改绑成功：注销旧绑定、注册新绑定、偏好写入新值', () async {
    final service = build();
    await service.activate(onTriggered: () {});
    registeredBindings.clear();

    final result = await service.saveBinding('<Super><Shift>x');
    expect(result, isA<ShortcutActivationSuccess>());
    expect(service.activeBinding, '<Super><Shift>x');
    expect(service.status, ShortcutRegistrationStatus.active);
    expect(registeredBindings, hasLength(1));
    expect(
      (await SharedPreferences.getInstance()).getString(
        MacosShortcutService.bindingKey,
      ),
      '<Super><Shift>x',
    );
  });

  test('改绑失败会回滚旧绑定，偏好设置保持旧值', () async {
    // 只让新绑定注册失败，旧绑定（默认值）仍可注册 → 回滚应成功。
    final service = build(failFor: {'<Super><Shift>x'});
    await service.activate(onTriggered: () {});
    final previous = service.activeBinding!;
    expect(previous, MacosShortcutService.defaultBinding);

    final result = await service.saveBinding('<Super><Shift>x');
    expect(result, isA<ShortcutActivationFailure>());
    final failure = result as ShortcutActivationFailure;
    expect(failure.restoredBinding, previous);
    expect(failure.rollbackFailed, isFalse);
    expect(service.status, ShortcutRegistrationStatus.active);
    expect(service.activeBinding, previous);
    expect(
      (await SharedPreferences.getInstance()).getString(
        MacosShortcutService.bindingKey,
      ),
      isNot('<Super><Shift>x'),
    );
  });

  test('改绑和回滚都失败时状态是 failed，UI 才能显示「未启用」', () async {
    // 先让默认值注册成功，再把默认值也变成「注册不上」：新绑定和旧绑定都失败。
    final failFor = <String>{'<Super><Shift>x'};
    final service = build(failFor: failFor);
    await service.activate(onTriggered: () {});
    expect(service.status, ShortcutRegistrationStatus.active);
    failFor.add(MacosShortcutService.defaultBinding);

    final result = await service.saveBinding('<Super><Shift>x');
    expect(result, isA<ShortcutActivationFailure>());
    final failure = result as ShortcutActivationFailure;
    expect(failure.rollbackFailed, isTrue);
    expect(service.status, ShortcutRegistrationStatus.failed);
    expect(service.activeBinding, isNull);
  });

  test('reactivate 在合并窗口内不会重复注册', () async {
    final service = build();
    await service.activate(onTriggered: () {});
    registeredBindings.clear();

    await service.reactivate();
    await service.reactivate();
    // 合并窗口（默认 1s）内直接复用上次结果，不重复走注册。
    expect(registeredBindings, isEmpty);
    expect(service.status, ShortcutRegistrationStatus.active);
  });

  test('reactivate 并发调用只跑一次注册（single-flight）', () async {
    // 关掉合并窗口，确保这条用例测的是 single-flight 而不是合并窗口。
    final service = MacosShortcutService(
      log: DiagnosticLogService(directory: logDirectory),
      retryDelay: Duration.zero,
      reactivateMergeWindow: Duration.zero,
      registerHotKey: (HotKey hotKey, void Function() onTriggered) async {
        registeredBindings.add(hotKey.identifier);
      },
      unregisterHotKey: (HotKey hotKey) async {
        unregisteredBindings.add(hotKey.identifier);
      },
    );
    await service.activate(onTriggered: () {});
    registeredBindings.clear();

    await Future.wait(<Future<ShortcutActivationResult>>[
      service.reactivate(),
      service.reactivate(),
      service.reactivate(),
    ]);
    expect(registeredBindings, hasLength(1));
  });

  test('clearBinding 注销并回到 inactive', () async {
    final service = build();
    await service.activate(onTriggered: () {});
    await service.clearBinding();
    expect(service.status, ShortcutRegistrationStatus.inactive);
    expect(service.activeBinding, isNull);
    expect(
      (await SharedPreferences.getInstance()).getString(
        MacosShortcutService.bindingKey,
      ),
      isNull,
    );
  });

  test('注销失败时中止改绑，不会注册新热键', () async {
    final failUnregisterFor = <String>{};
    final service = build(failUnregisterFor: failUnregisterFor);
    await service.activate(onTriggered: () {});
    registeredBindings.clear();

    // 从此旧绑定注销不掉：改绑必须中止，绝不能注册出新热键。
    failUnregisterFor.add(MacosShortcutService.defaultBinding);

    final result = await service.saveBinding('<Super><Shift>x');
    expect(result, isA<ShortcutActivationFailure>());
    expect(registeredBindings, isEmpty);
  });

  test('clearBinding 注销失败时不删偏好设置', () async {
    final service = build(
      failUnregisterFor: <String>{MacosShortcutService.defaultBinding},
    );
    await service.activate(onTriggered: () {});
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(MacosShortcutService.bindingKey),
      MacosShortcutService.defaultBinding,
    );

    await service.clearBinding();
    expect(service.status, ShortcutRegistrationStatus.failed);
    // 注销没成功就删偏好，会变成「配置里没有、系统里还活着」。
    expect(
      preferences.getString(MacosShortcutService.bindingKey),
      MacosShortcutService.defaultBinding,
    );
  });

  test('历史默认值会被迁移到当前默认值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MacosShortcutService.bindingKey: '<Alt>z',
    });
    final service = build();
    await service.activate(onTriggered: () {});
    expect(service.activeBinding, MacosShortcutService.defaultBinding);
  });
}

/// 从 HotKey 反推绑定字符串（测试里只需要区分几个固定组合）。
String _bindingOf(HotKey hotKey) {
  final buffer = StringBuffer();
  for (final modifier in hotKey.modifiers ?? const <HotKeyModifier>[]) {
    buffer.write(switch (modifier) {
      HotKeyModifier.alt => '<Alt>',
      HotKeyModifier.control => '<Control>',
      HotKeyModifier.shift => '<Shift>',
      HotKeyModifier.meta => '<Super>',
      HotKeyModifier.capsLock => '<CapsLock>',
      HotKeyModifier.fn => '<Fn>',
    });
  }
  buffer.write(hotKey.logicalKey.keyLabel.toLowerCase());
  return buffer.toString();
}
