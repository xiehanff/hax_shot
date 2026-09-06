import 'package:easy_shot/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tray host has no application window UI', (tester) async {
    await tester.pumpWidget(const EasyShotApp(captureMode: false));

    expect(find.byType(TrayHostPage), findsOneWidget);
    expect(find.text('Easy Shot'), findsNothing);
  });
}
