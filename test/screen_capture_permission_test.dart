import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/settings/screen_capture_permission.dart';

void main() {
  test('reset 调用 tccutil reset ScreenCapture <bundleId>', () async {
    final calls = <List<String>>[];
    final service = ScreenCapturePermission(
      processRunner: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        return ProcessResult(0, 0, '', '');
      },
    );

    await service.reset();

    if (!Platform.isMacOS) {
      expect(calls, isEmpty, reason: '非 macOS 平台不应该执行 tccutil');
      return;
    }
    expect(calls, hasLength(1));
    expect(calls.single, [
      'tccutil',
      'reset',
      'ScreenCapture',
      ScreenCapturePermission.bundleIdentifier,
    ]);
  });

  test('tccutil 失败时抛出可读错误', () async {
    final service = ScreenCapturePermission(
      processRunner: (executable, arguments) async =>
          ProcessResult(0, 3, '', 'tccutil: failed'),
    );

    if (!Platform.isMacOS) return;
    await expectLater(
      service.reset(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('tccutil'),
        ),
      ),
    );
  });
}
