import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/settings/gnome_shortcut_service.dart';

void main() {
  test('reads, saves and clears GNOME shortcut bindings', () async {
    final calls = <List<String>>[];
    Future<ProcessResult> run(String executable, List<String> arguments) async {
      expect(executable, 'gsettings');
      calls.add([...arguments]);
      if (arguments[0] == 'get' && arguments[2] == 'binding') {
        return ProcessResult(1, 0, "'<Alt>z'\n", '');
      }
      if (arguments[0] == 'get' && arguments[2] == 'custom-keybindings') {
        return ProcessResult(1, 0, "['/existing/']\n", '');
      }
      return ProcessResult(1, 0, '', '');
    }

    final service = GnomeShortcutService(
      executablePath: '/opt/hax shot/hax_shot',
      processRunner: run,
    );

    expect(await service.readBinding(), '<Alt>z');
    await service.saveBinding('<Control>k');
    await service.clearBinding();

    expect(
      calls,
      contains([
        'set',
        GnomeShortcutService.bindingSchema,
        'command',
        '"/opt/hax shot/hax_shot" --capture',
      ]),
    );
    expect(
      calls,
      contains([
        'set',
        GnomeShortcutService.bindingSchema,
        'binding',
        '<Control>k',
      ]),
    );
    expect(
      calls,
      contains([
        'set',
        GnomeShortcutService.bindingSchema,
        'binding',
        '',
      ]),
    );
    expect(
      calls.any(
        (arguments) =>
            arguments.length == 4 &&
            arguments[0] == 'set' &&
            arguments[1] == GnomeShortcutService.mediaKeysSchema &&
            arguments[2] == 'custom-keybindings' &&
            arguments[3].contains(GnomeShortcutService.keyPath),
      ),
      isTrue,
    );
  });
}
