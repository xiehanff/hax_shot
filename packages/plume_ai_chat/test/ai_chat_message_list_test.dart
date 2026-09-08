import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

void main() {
  testWidgets('uses stable message ids and optional trailing builder', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: AiChatMessageList(
            controller: controller,
            messages: const <ChatMessage>[
              ChatMessage(
                author: MessageAuthor.human,
                text: 'hello',
                id: 'user-1',
              ),
              ChatMessage(author: MessageAuthor.ai, text: 'answer', id: 'ai-1'),
            ],
            messageBuilder:
                (BuildContext context, ChatMessage message, int index) {
                  return Text(message.text);
                },
            trailingBuilder: (BuildContext context) => const Text('follow-up'),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey<String>('user-1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ai-1')), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('answer'), findsOneWidget);
    expect(find.text('follow-up'), findsOneWidget);
  });

  testWidgets('host controls the empty presentation', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AiChatMessageList(
          controller: controller,
          messages: const <ChatMessage>[],
          messageBuilder: (_, __, ___) => const SizedBox.shrink(),
          emptyBuilder: (_) => const Text('custom empty'),
        ),
      ),
    );

    expect(find.text('custom empty'), findsOneWidget);
  });
}
