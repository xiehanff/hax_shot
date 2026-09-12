import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

class _QueuedBackend implements AiBackend {
  final Completer<void> firstCancelGate = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  late final StreamController<AiStreamEvent> firstStream =
      StreamController<AiStreamEvent>(onCancel: () => firstCancelGate.future);
  late final StreamController<AiStreamEvent> secondStream =
      StreamController<AiStreamEvent>();
  int calls = 0;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) {
    calls++;
    if (calls == 1) {
      return firstStream.stream;
    }
    if (!secondStarted.isCompleted) {
      secondStarted.complete();
    }
    return secondStream.stream;
  }
}

class _SingleStreamBackend implements AiBackend {
  final StreamController<AiStreamEvent> stream =
      StreamController<AiStreamEvent>();
  AiBackendRequest? lastRequest;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) {
    lastRequest = request;
    return stream.stream;
  }
}

class _CancelableBackend implements AiBackend {
  final Completer<void> canceled = Completer<void>();
  late final StreamController<AiStreamEvent> stream =
      StreamController<AiStreamEvent>(
        onCancel: () {
          if (!canceled.isCompleted) {
            canceled.complete();
          }
        },
      );

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) => stream.stream;
}

void main() {
  test('old stopped Future cannot clear a newer send state', () async {
    final _QueuedBackend backend = _QueuedBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );

    final Future<AiChatTurnResult> first = controller.send(
      input: const AiChatInput(text: 'first'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.isGenerating, isTrue);
    expect(controller.stop(), isTrue);
    expect(controller.isGenerating, isFalse);
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'first');

    final Future<AiChatTurnResult> second = controller.send(
      input: const AiChatInput(text: 'second'),
    );
    expect(controller.isGenerating, isTrue);

    backend.firstCancelGate.complete();
    await first;

    expect(controller.isGenerating, isTrue);

    await backend.secondStarted.future;
    backend.secondStream
      ..add(const AiStreamEvent(text: 'second answer'))
      ..close();
    final AiChatTurnResult result = await second;

    expect(result.content, 'second answer');
    expect(controller.isGenerating, isFalse);
    expect(
      controller.messages.map((ChatMessage message) => message.text),
      <String>['first', 'second', 'second answer'],
    );
  });

  test('stopPrevious finalizes old placeholder before the new turn', () async {
    final _QueuedBackend backend = _QueuedBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );

    final Future<AiChatTurnResult> first = controller.send(
      input: const AiChatInput(text: 'first'),
    );
    await Future<void>.delayed(Duration.zero);

    final Future<AiChatTurnResult> second = controller.submit(
      submission: const AiChatSubmission(
        displayText: 'second',
        userMessage: AiChatHistoryMessage.user(content: 'second prompt'),
        stopPrevious: true,
      ),
    );

    expect(
      controller.messages.map((ChatMessage message) => message.text),
      <String>['first', 'second', ''],
    );
    expect(controller.messages.last.isLoading, isTrue);

    backend.firstCancelGate.complete();
    await first;
    await backend.secondStarted.future;
    backend.secondStream
      ..add(const AiStreamEvent(text: 'second answer'))
      ..close();
    await second;

    expect(
      controller.messages.map((ChatMessage message) => message.text),
      <String>['first', 'second', 'second answer'],
    );
    expect(controller.messages.last.isLoading, isFalse);
  });

  test(
    'streaming controller hides follow-up protocol tags from UI state',
    () async {
      final _SingleStreamBackend backend = _SingleStreamBackend();
      final AiChatController controller = AiChatController(
        session: AiChatSession(backend: backend),
      );

      final Future<AiChatTurnResult> future = controller.send(
        input: const AiChatInput(text: 'hello'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages, hasLength(2));
      expect(controller.messages.last.isLoading, isTrue);

      backend.stream
        ..add(
          const AiStreamEvent(
            text:
                '正文<plume_follow_up_suggestions>["继续解释"]</plume_follow_up_suggestions>',
          ),
        )
        ..close();

      final AiChatTurnResult result = await future;
      expect(result.content, '正文');
      expect(controller.streamingText, '正文');
      expect(controller.followUpSuggestions, <String>['继续解释']);
      expect(controller.messages.last.text, '正文');
      expect(controller.messages.last.isLoading, isFalse);
    },
  );

  test('submission separates display content from transport prompt', () async {
    final _SingleStreamBackend backend = _SingleStreamBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );

    final Future<AiChatTurnResult> future = controller.submit(
      submission: const AiChatSubmission(
        displayText: '解释这段选区',
        userMessage: AiChatHistoryMessage.user(
          content: '请解释以下内容，并结合页面全文上下文：rich prompt',
        ),
        systemPrompt: 'system',
        stopPrevious: true,
        deferHistoryCommit: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages.first.text, '解释这段选区');
    expect(
      backend.lastRequest!.history.last.content,
      '请解释以下内容，并结合页面全文上下文：rich prompt',
    );
    expect(backend.lastRequest!.systemPrompt, 'system');
    expect(controller.history, isEmpty);

    backend.stream
      ..add(const AiStreamEvent(text: '解释结果'))
      ..close();
    await future;

    expect(controller.messages.last.text, '解释结果');
    expect(
      controller.history.map((AiChatHistoryMessage message) => message.content),
      <String>['请解释以下内容，并结合页面全文上下文：rich prompt', '解释结果'],
    );
  });

  test('new conversation clears transport and presentation state', () async {
    final _SingleStreamBackend backend = _SingleStreamBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );

    final Future<AiChatTurnResult> future = controller.send(
      input: const AiChatInput(text: 'hello'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages, isNotEmpty);

    controller.newConversation();
    expect(controller.messages, isEmpty);
    expect(controller.history, isEmpty);
    expect(controller.isGenerating, isFalse);

    await backend.stream.close();
    await future;
    expect(controller.messages, isEmpty);
    expect(controller.history, isEmpty);
  });

  test(
    'controller disposal cancels transport and invalidates UI state',
    () async {
      final _CancelableBackend backend = _CancelableBackend();
      final AiChatController controller = AiChatController(
        session: AiChatSession(backend: backend),
      );

      final Future<AiChatTurnResult> future = controller.send(
        input: const AiChatInput(text: 'hello'),
      );
      await Future<void>.delayed(Duration.zero);

      controller.onClose();
      await backend.canceled.future;
      await future;

      expect(controller.messages, isEmpty);
      expect(controller.history, isEmpty);
      expect(controller.isGenerating, isFalse);
    },
  );
}
