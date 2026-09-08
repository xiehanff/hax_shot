import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

class _CountingBackend implements AiBackend {
  int calls = 0;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) {
    calls++;
    return const Stream<AiStreamEvent>.empty();
  }
}

class _FallbackFailureBackend implements AiBackend {
  int calls = 0;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) {
    calls++;
    return Stream<AiStreamEvent>.error(StateError('vision rejected'));
  }
}

const AiChatSubmission _submission = AiChatSubmission(
  displayText: 'question',
  userMessage: AiChatHistoryMessage.user(content: 'prompt'),
);

void main() {
  test('Stop absorbs an error from stale submission preparation', () async {
    final _CountingBackend backend = _CountingBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );
    final Completer<AiChatSubmission> preparation =
        Completer<AiChatSubmission>();

    final Future<AiChatTurnResult> future = controller.submit(
      submission: _submission,
      prepareSubmission: () => preparation.future,
    );

    expect(controller.stop(), isTrue);
    preparation.completeError(StateError('stale preparation failed'));

    final AiChatTurnResult result = await future;
    expect(result.stopped, isTrue);
    expect(backend.calls, 0);
    expect(controller.history, isEmpty);
    expect(
      controller.messages.map((ChatMessage message) => message.text),
      <String>['question'],
    );
  });

  test('new conversation absorbs an error from stale preparation', () async {
    final _CountingBackend backend = _CountingBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );
    final Completer<AiChatSubmission> preparation =
        Completer<AiChatSubmission>();

    final Future<AiChatTurnResult> future = controller.submit(
      submission: _submission,
      prepareSubmission: () => preparation.future,
    );

    controller.newConversation();
    preparation.completeError(StateError('old document failed'));

    final AiChatTurnResult result = await future;
    expect(result.stopped, isTrue);
    expect(backend.calls, 0);
    expect(controller.history, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.isGenerating, isFalse);
  });

  test('Stop absorbs an error from stale fallback construction', () async {
    final _FallbackFailureBackend backend = _FallbackFailureBackend();
    final AiChatController controller = AiChatController(
      session: AiChatSession(backend: backend),
    );
    final Completer<void> fallbackStarted = Completer<void>();
    final Completer<AiChatSubmission?> fallback =
        Completer<AiChatSubmission?>();

    final Future<AiChatTurnResult> future = controller.submit(
      submission: const AiChatSubmission(
        displayText: 'vision question',
        userMessage: AiChatHistoryMessage.user(content: 'vision prompt'),
        stopPrevious: true,
        deferHistoryCommit: true,
      ),
      fallbackBuilder: (Object error) async {
        expect(error, isA<StateError>());
        fallbackStarted.complete();
        return fallback.future;
      },
    );

    await fallbackStarted.future;
    expect(backend.calls, 1);
    expect(controller.stop(), isTrue);
    fallback.completeError(StateError('stale fallback failed'));

    final AiChatTurnResult result = await future;
    expect(result.stopped, isTrue);
    expect(backend.calls, 1);
    expect(controller.history, isEmpty);
    expect(
      controller.messages.map((ChatMessage message) => message.text),
      <String>['vision question'],
    );
  });
}
