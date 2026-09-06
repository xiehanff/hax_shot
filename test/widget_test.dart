import 'package:hax_shot/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tray host has no application window UI', (tester) async {
    await tester.pumpWidget(const HaxShotApp(captureMode: false));

    expect(find.byType(TrayHostPage), findsOneWidget);
    expect(find.text('Hax Shot'), findsNothing);
  });
}
