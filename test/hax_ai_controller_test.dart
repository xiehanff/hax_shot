import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/ai/controllers/hax_ai_controller.dart';
import 'package:hax_shot/models/hax_ai_action.dart';
import 'package:hax_shot/features/ai/services/hax_ai_prompts.dart';
import 'package:hax_shot/features/ai/services/hax_ai_service.dart';
import 'package:hax_shot/features/ai/services/hax_ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('action labels and prompts describe all screenshot actions', () {
    expect(HaxAiAction.translate.label, '翻译截图');
    expect(HaxAiAction.explain.label, '解释截图');
    expect(HaxAiAction.deepUnderstand.label, '深入理解截图');

    expect(HaxAiPrompts.forAction('translate'), HaxAiPrompts.translate());
    expect(HaxAiPrompts.forAction('explain'), HaxAiPrompts.explain());
    expect(
      HaxAiPrompts.forAction('deepUnderstand'),
      HaxAiPrompts.deepUnderstand(),
    );
    expect(HaxAiPrompts.forAction('unknown'), HaxAiPrompts.explain());
  });

  test(
    'controller loads settings and exposes host state transitions',
    () async {
      SharedPreferences.setMockInitialValues({
        'hax_shot.deepseek_api_key': ' saved-key ',
      });
      final HaxAiService service = HaxAiService(
        settingsStore: HaxAiSettingsStore(),
      );
      final HaxAiController controller = HaxAiController(service: service);
      addTearDown(controller.onClose);

      controller.onInit();
      await service.init();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.apiKey, 'saved-key');
      expect(controller.apiKeyController.text, 'saved-key');
      expect(controller.isLoading, isFalse);

      controller.showSettings();
      expect(controller.mode, HaxAiSidebarMode.settings);
      controller.showConversation();
      expect(controller.mode, HaxAiSidebarMode.conversation);

      controller.apiKeyController.text = ' updated-key ';
      controller.onApiKeyChanged(controller.apiKeyController.text);
      expect(controller.state.apiKey, 'updated-key');
    },
  );

  test('controller avoids transport for empty input or screenshot', () async {
    SharedPreferences.setMockInitialValues({});
    final HaxAiService service = HaxAiService(
      settingsStore: HaxAiSettingsStore(),
    );
    final HaxAiController controller = HaxAiController(service: service);
    addTearDown(controller.onClose);

    controller.onInit();
    await service.init();
    await Future<void>.delayed(Duration.zero);

    await controller.sendMessage('   ');
    expect(controller.mode, HaxAiSidebarMode.conversation);
    expect(controller.messages, isEmpty);

    await controller.sendMessage('hello');
    expect(controller.mode, HaxAiSidebarMode.settings);
    expect(controller.messages, isEmpty);

    controller.inputController.text = 'draft';
    await controller.sendScreenshotAction(
      action: HaxAiAction.explain,
      pngBytes: Uint8List(0),
    );
    expect(controller.inputController.text, 'draft');
    expect(controller.messages, isEmpty);

    controller.newConversation();
    expect(controller.inputController.text, isEmpty);
    expect(controller.messages, isEmpty);
  });
}
