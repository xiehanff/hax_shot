import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/capture/annotation.dart';
import 'package:hax_shot/features/settings/autostart_service.dart';

void main() {
  test('maps an annotation from overlay coordinates to image pixels', () {
    const annotation = ScreenshotAnnotation(
      tool: CaptureTool.rectangle,
      start: Offset(120, 80),
      end: Offset(320, 280),
      color: Color(0xFFE53935),
    );

    final mapped = annotation.translatedAndScaled(
      origin: const Offset(100, 50),
      scale: 2,
    );

    expect(mapped.rect, const Rect.fromLTWH(10, 15, 100, 100));
    expect(mapped.color, const Color(0xFFE53935));
  });

  test('autostart service creates and removes a user desktop entry', () async {
    final configHome = await Directory.systemTemp.createTemp('hax-shot-test-');
    addTearDown(() => configHome.delete(recursive: true));
    final service = AutostartService(
      configHome: configHome.path,
      executablePath: '/opt/hax shot/hax_shot',
    );

    expect(await service.isEnabled(), isFalse);
    await service.setEnabled(true);
    expect(await service.isEnabled(), isTrue);

    final desktop = File(
      '${configHome.path}/autostart/${AutostartService.desktopFileName}',
    );
    final contents = await desktop.readAsString();
    expect(contents, contains('Exec="/opt/hax shot/hax_shot"'));
    expect(contents, contains('X-GNOME-Autostart-enabled=true'));

    await service.setEnabled(false);
    expect(await service.isEnabled(), isFalse);
    expect(await desktop.exists(), isFalse);
  });
}
