import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/ai/controllers/hax_ai_controller.dart';
import 'package:hax_shot/features/ai/services/hax_ai_service.dart';
import 'package:hax_shot/features/ai/services/hax_ai_settings_store.dart';
import 'package:hax_shot/features/ai/views/ai_page.dart';
import 'package:hax_shot/features/ai/views/widgets/ai_colors.dart';
import 'package:hax_shot/features/window/rounded_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpAiPage(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = HaxAiService(settingsStore: HaxAiSettingsStore());
    final controller = HaxAiController(service: service);
    addTearDown(controller.onClose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: AiPage(controller: controller, onClose: () {}),
      ),
    );
    await tester.pump();
  }

  testWidgets('AI 面板用 RoundedWindow 裁圆角（配合透明窗口）', (tester) async {
    await pumpAiPage(tester);
    expect(find.byType(RoundedWindow), findsOneWidget);
  });

  testWidgets('AI 面板顶部条用比正文略亮的底色做区分', (tester) async {
    await pumpAiPage(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == AppColors.titleBarBg,
      ),
      findsOneWidget,
    );
    // 顶部条要和正文底色不同，否则这个区分就没意义了。
    expect(AppColors.titleBarBg, isNot(AppColors.scaffoldBg));
  });
}
