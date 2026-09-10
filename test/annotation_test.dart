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

  test('maps text content and font size to image pixels', () {
    const annotation = ScreenshotAnnotation(
      tool: CaptureTool.text,
      start: Offset(120, 80),
      end: Offset(320, 140),
      color: Color(0xFF2E9B59),
      text: '截图完成',
      fontSize: 24,
    );

    final mapped = annotation.translatedAndScaled(
      origin: const Offset(100, 50),
      scale: 2,
    );

    expect(mapped.text, '截图完成');
    expect(mapped.rect, const Rect.fromLTWH(10, 15, 100, 30));
    expect(mapped.fontSize, 12);
  });

  test(
    'xdg autostart service creates and removes a user desktop entry',
    () async {
      final configHome = await Directory.systemTemp.createTemp(
        'hax-shot-test-',
      );
      addTearDown(() => configHome.delete(recursive: true));
      final service = XdgAutostartService(
        configHome: configHome.path,
        executablePath: '/opt/hax shot/hax_shot',
      );

      expect(await service.isEnabled(), isFalse);
      await service.setEnabled(true);
      expect(await service.isEnabled(), isTrue);

      final desktop = File(
        '${configHome.path}/autostart/${XdgAutostartService.desktopFileName}',
      );
      final contents = await desktop.readAsString();
      expect(contents, contains('Exec="/opt/hax shot/hax_shot"'));
      expect(contents, contains('X-GNOME-Autostart-enabled=true'));

      await service.setEnabled(false);
      expect(await service.isEnabled(), isFalse);
      expect(await desktop.exists(), isFalse);
    },
  );

  test('macOS autostart service writes a LaunchAgent plist', () async {
    final home = await Directory.systemTemp.createTemp('hax-shot-macos-test-');
    addTearDown(() => home.delete(recursive: true));
    final service = MacosAutostartService(
      homeDirectory: home.path,
      executablePath: '/Applications/Hax Shot.app/Contents/MacOS/hax_shot',
    );

    expect(await service.isEnabled(), isFalse);
    await service.setEnabled(true);
    expect(await service.isEnabled(), isTrue);

    final plist = File(
      '${home.path}/Library/LaunchAgents/${MacosAutostartService.label}.plist',
    );
    final contents = await plist.readAsString();
    expect(contents, contains('<key>RunAtLoad</key>'));
    expect(contents, contains('<key>Label</key>'));
    // Label 必须和 macOS Runner 的 PRODUCT_BUNDLE_IDENTIFIER 一致，
    // 否则 launchd 里的实例会和 app 对不上。
    expect(contents, contains('<string>com.github.xiehanff.haxShot</string>'));
    expect(contents, contains('<key>ProgramArguments</key>'));
    expect(contents, contains('<array>'));
    expect(
      contents,
      contains(
        '<string>/Applications/Hax Shot.app/Contents/MacOS/hax_shot</string>',
      ),
    );

    await service.setEnabled(false);
    expect(await service.isEnabled(), isFalse);
    expect(await plist.exists(), isFalse);
  });

  test('macOS autostart service escapes XML in the executable path', () async {
    final home = await Directory.systemTemp.createTemp('hax-shot-plist-test-');
    addTearDown(() => home.delete(recursive: true));
    final service = MacosAutostartService(
      homeDirectory: home.path,
      executablePath: '/Applications/Hax & <Shot>.app/Contents/MacOS/hax_shot',
    );

    await service.setEnabled(true);
    final plist = File(
      '${home.path}/Library/LaunchAgents/${MacosAutostartService.label}.plist',
    );
    final contents = await plist.readAsString();

    expect(contents, contains('Hax &amp; &lt;Shot&gt;'));
    expect(contents, isNot(contains('Hax & <Shot>')));
    // plist 结构必须是平衡的，否则 launchd 会静默忽略。
    expect(contents, endsWith('</plist>\n'));
    expect(RegExp(r'<array>').allMatches(contents).length, 1);
    expect(RegExp(r'</array>').allMatches(contents).length, 1);
  });
}
