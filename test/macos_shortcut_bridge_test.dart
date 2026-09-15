import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/diagnostics/diagnostic_log.dart';
import 'package:hax_shot/features/settings/macos_shortcut_bridge.dart';
import 'package:hax_shot/features/settings/macos_shortcut_service.dart';
import 'package:hax_shot/features/settings/shortcut_registration.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组用例覆盖本轮最重要的一条：**原生 register 的失败必须能传到 Dart**。
///
/// 以前 `hotkey_manager_macos` 无条件 `result(true)`，Carbon 注册失败时 Dart 侧
/// 完全看不出来，于是设置页显示“已启用”、用户按下去毫无反应。现在桥返回真实
/// OSStatus，这里用 mock channel 复现「Carbon 拒绝」并断言状态机变成 failed。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MacosShortcutBridge.channelName);
  late Directory logDirectory;
  late List<MethodCall> calls;

  void mockNative(Map<String, Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    logDirectory = Directory.systemTemp.createTempSync('hax_shot_bridge_test');
    calls = <MethodCall>[];
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      logDirectory.deleteSync(recursive: true);
    } on Object {
      // 忽略清理失败。
    }
  });

  MacosShortcutService service() => MacosShortcutService(
    log: DiagnosticLogService(directory: logDirectory),
    retryDelay: Duration.zero,
  );

  test('Carbon 返回失败时状态是 failed，而不是假装已启用', () async {
    mockNative(
      (_) => <String, Object?>{
        'ok': false,
        'osStatus': -9878, // eventHotKeyExistsErr
        'message': '这个组合已经被占用',
      },
    );

    final result = await service().activate(onTriggered: () {});

    expect(result, isA<ShortcutActivationFailure>());
    final failure = result as ShortcutActivationFailure;
    expect(failure.error, isA<ShortcutNativeException>());
    expect((failure.error as ShortcutNativeException).osStatus, -9878);
    expect('${failure.error}', contains('-9878'));
  });

  test('注册成功时把 Carbon 虚拟键码和修饰键发给原生', () async {
    mockNative((_) => <String, Object?>{'ok': true, 'osStatus': 0});

    final result = await service().activate(onTriggered: () {});

    expect(result, isA<ShortcutActivationSuccess>());
    final registerCall = calls.firstWhere((call) => call.method == 'register');
    final arguments = registerCall.arguments as Map<Object?, Object?>;
    // '<Alt><Shift>z'：Z 在 macOS 上是 kVK_ANSI_Z = 6，不是 USB HID 的 0x1d。
    expect(arguments['keyCode'], 6);
    expect(arguments['modifiers'], containsAll(<String>['alt', 'shift']));
  });

  test('注销失败时 clearBinding 返回 false，UI 不会报“已删除”', () async {
    mockNative(
      (call) => call.method == 'unregister'
          ? <String, Object?>{'ok': false, 'osStatus': -1, 'message': '注销被拒'}
          : <String, Object?>{'ok': true, 'osStatus': 0},
    );

    final shortcut = service();
    await shortcut.activate(onTriggered: () {});
    expect(await shortcut.clearBinding(), isFalse);
    expect(shortcut.status, ShortcutRegistrationStatus.failed);
    // 配置不能被删：系统里可能还留着这个组合。
    expect(
      (await SharedPreferences.getInstance()).getString(
        MacosShortcutService.bindingKey,
      ),
      MacosShortcutService.defaultBinding,
    );
  });

  test('原生按键回调触发 onTriggered', () async {
    mockNative((_) => <String, Object?>{'ok': true, 'osStatus': 0});
    var triggered = 0;
    await service().activate(onTriggered: () => triggered++);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          MacosShortcutBridge.channelName,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('triggered'),
          ),
          (_) {},
        );

    expect(triggered, 1);
  });
}
