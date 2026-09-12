import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

class _QueuedBackend implements AiBackend {
  final Completer<void> firstCancelGate = Completer<void>();
  final List<AiBackendRequest> requests = <AiBackendRequest>[];
  final List<StreamController<AiStreamEvent>> streams =
      <StreamController<AiStreamEvent>>[];
  bool firstCanceled = false;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) {
    requests.add(request);
    final int index = streams.length;
    final StreamController<AiStreamEvent> controller =
        StreamController<AiStreamEvent>(
          onCancel: () {
            if (index == 0) {
              firstCanceled = true;
              return firstCancelGate.future;
            }
            return null;
          },
        );
    streams.add(controller);
    return controller.stream;
  }

  Future<void> waitForCalls(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> closeAll() async {
    for (final StreamController<AiStreamEvent> stream in streams) {
      if (!stream.isClosed) {
        await stream.close();
      }
    }
  }
}

void main() {
  test('Stop prefers active transport over a later pending turn', () async {
    final _QueuedBackend backend = _QueuedBackend();
    final AiChatSession session = AiChatSession(backend: backend);

    final Future<AiChatTurnResult> first = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'first'),
      onPreview: (_, _) {},
    );
    await backend.waitForCalls(1);

    final Future<AiChatTurnResult> second = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'second'),
      onPreview: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests, hasLength(1));

    expect(session.stopActiveTurn(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(backend.firstCanceled, isTrue);

    backend.firstCancelGate.complete();
    final AiChatTurnResult firstResult = await first;
    expect(firstResult.stopped, isTrue);

    await backend.waitForCalls(2);
    expect(backend.requests[1].history.last.content, 'second');

    backend.streams[1]
      ..add(const AiStreamEvent(text: 'second answer'))
      ..close();
    final AiChatTurnResult secondResult = await second;

    expect(secondResult.stopped, isFalse);
    expect(secondResult.content, 'second answer');
    expect(
      session.history.map((AiChatHistoryMessage message) => message.content),
      <String>['second', 'second answer'],
    );
    await backend.closeAll();
  });
}
