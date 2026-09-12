import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

class _ControlledBackend implements AiBackend {
  _ControlledBackend({this.blockFirstCancel = false});

  final bool blockFirstCancel;
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
              if (blockFirstCancel) {
                return firstCancelGate.future;
              }
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
  test('commits user and assistant history in order', () async {
    final _ControlledBackend backend = _ControlledBackend();
    final AiChatSession session = AiChatSession(backend: backend);

    final Future<AiChatTurnResult> future = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'hello'),
      onPreview: (_, _) {},
    );

    await backend.waitForCalls(1);
    backend.streams.single
      ..add(const AiStreamEvent(text: 'hi'))
      ..close();

    final AiChatTurnResult result = await future;
    expect(result.content, 'hi');
    expect(session.history.map((e) => e.content), <String>['hello', 'hi']);
  });

  test('history is a stable live read-only view', () async {
    final _ControlledBackend backend = _ControlledBackend();
    final AiChatSession session = AiChatSession(backend: backend);
    final List<AiChatHistoryMessage> view = session.history;

    expect(identical(view, session.history), isTrue);
    expect(
      () => view.add(const AiChatHistoryMessage.user(content: 'x')),
      throwsUnsupportedError,
    );

    final Future<AiChatTurnResult> future = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'hello'),
      onPreview: (_, _) {},
    );
    await backend.waitForCalls(1);
    expect(view.map((e) => e.content), <String>['hello']);

    backend.streams.single
      ..add(const AiStreamEvent(text: 'hi'))
      ..close();
    await future;
    expect(view.map((e) => e.content), <String>['hello', 'hi']);
  });

  test(
    'high-frequency chunks are batched into one preview per 40ms window',
    () async {
      final _ControlledBackend backend = _ControlledBackend();
      final AiChatSession session = AiChatSession(backend: backend);
      final List<String> previews = <String>[];

      final Future<AiChatTurnResult> future = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'hello'),
        onPreview: (String text, String reasoning) => previews.add(text),
      );
      await backend.waitForCalls(1);

      for (int index = 0; index < 10; index++) {
        backend.streams.single.add(AiStreamEvent(text: '$index'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(previews, <String>['0123456789']);

      await backend.streams.single.close();
      expect((await future).content, '0123456789');
    },
  );

  test('stream error cancels pending preview callback', () async {
    final _ControlledBackend backend = _ControlledBackend();
    final AiChatSession session = AiChatSession(backend: backend);
    int previewCount = 0;

    final Future<AiChatTurnResult> future = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'hello'),
      onPreview: (_, _) => previewCount++,
    );
    await backend.waitForCalls(1);

    backend.streams.single
      ..add(const AiStreamEvent(text: 'partial'))
      ..addError(StateError('network failed'));

    await expectLater(future, throwsA(isA<StateError>()));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(previewCount, 0);
    expect(session.history, isEmpty);
    await backend.closeAll();
  });

  test('Stop before first content rolls back the user turn', () async {
    final _ControlledBackend backend = _ControlledBackend();
    final AiChatSession session = AiChatSession(backend: backend);

    final Future<AiChatTurnResult> future = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'hello'),
      onPreview: (_, _) {},
    );

    await backend.waitForCalls(1);
    expect(session.stopActiveTurn(), isTrue);

    final AiChatTurnResult result = await future;
    expect(result.stopped, isTrue);
    expect(backend.firstCanceled, isTrue);
    expect(session.history, isEmpty);
    await backend.closeAll();
  });

  test(
    'Stop after partial content commits partial assistant history',
    () async {
      final _ControlledBackend backend = _ControlledBackend();
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> future = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'hello'),
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);
      backend.streams.single.add(const AiStreamEvent(text: 'partial'));
      await Future<void>.delayed(Duration.zero);

      expect(session.stopActiveTurn(), isTrue);
      final AiChatTurnResult result = await future;

      expect(result.stopped, isTrue);
      expect(result.content, 'partial');
      expect(session.history.map((e) => e.content), <String>[
        'hello',
        'partial',
      ]);
      await backend.closeAll();
    },
  );

  test(
    'Stop then immediate send waits for partial history finalization',
    () async {
      final _ControlledBackend backend = _ControlledBackend(
        blockFirstCancel: true,
      );
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> first = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'first'),
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);
      backend.streams[0].add(const AiStreamEvent(text: 'partial answer'));
      await Future<void>.delayed(Duration.zero);
      expect(session.stopActiveTurn(), isTrue);

      final Future<AiChatTurnResult> second = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'second'),
        onPreview: (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, hasLength(1));

      backend.firstCancelGate.complete();
      expect((await first).stopped, isTrue);
      await backend.waitForCalls(2);

      expect(backend.requests[1].history.map((e) => e.content), <String>[
        'first',
        'partial answer',
        'second',
      ]);

      backend.streams[1]
        ..add(const AiStreamEvent(text: 'second answer'))
        ..close();
      await second;
      expect(session.history.map((e) => e.content), <String>[
        'first',
        'partial answer',
        'second',
        'second answer',
      ]);
      await backend.closeAll();
    },
  );

  test(
    'Stop before first token then immediate send excludes rolled-back user',
    () async {
      final _ControlledBackend backend = _ControlledBackend(
        blockFirstCancel: true,
      );
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> first = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'old'),
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);
      expect(session.stopActiveTurn(), isTrue);

      final Future<AiChatTurnResult> second = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'new'),
        onPreview: (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, hasLength(1));

      backend.firstCancelGate.complete();
      final AiChatTurnResult firstResult = await first;
      expect(firstResult.stopped, isTrue);
      expect(firstResult.content, isEmpty);
      await backend.waitForCalls(2);

      expect(backend.requests[1].history.map((e) => e.content), <String>[
        'new',
      ]);

      backend.streams[1]
        ..add(const AiStreamEvent(text: 'answer'))
        ..close();
      await second;
      expect(session.history.map((e) => e.content), <String>['new', 'answer']);
      await backend.closeAll();
    },
  );

  test('pending turn can be stopped before it reaches transport', () async {
    final _ControlledBackend backend = _ControlledBackend(
      blockFirstCancel: true,
    );
    final AiChatSession session = AiChatSession(backend: backend);

    final Future<AiChatTurnResult> first = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'first'),
      onPreview: (_, _) {},
    );
    await backend.waitForCalls(1);
    backend.streams[0].add(const AiStreamEvent(text: 'partial'));
    await Future<void>.delayed(Duration.zero);
    expect(session.stopActiveTurn(), isTrue);

    final Future<AiChatTurnResult> second = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'second'),
      onPreview: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.stopActiveTurn(), isTrue);

    backend.firstCancelGate.complete();
    await first;
    final AiChatTurnResult secondResult = await second;

    expect(secondResult.stopped, isTrue);
    expect(backend.requests, hasLength(1));
    expect(session.history.map((e) => e.content), <String>['first', 'partial']);
    await backend.closeAll();
  });

  test(
    'deferred turn is visible to transport but not public history before commit',
    () async {
      final _ControlledBackend backend = _ControlledBackend();
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> future = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'tool prompt'),
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );

      await backend.waitForCalls(1);
      expect(session.history, isEmpty);
      expect(backend.requests.single.history.single.content, 'tool prompt');

      backend.streams.single
        ..add(const AiStreamEvent(text: 'answer'))
        ..close();
      await future;

      expect(
        session.history.map((AiChatHistoryMessage e) => e.content),
        <String>['tool prompt', 'answer'],
      );
    },
  );

  test(
    'latest-wins stops a pending tool turn before it reaches transport',
    () async {
      final _ControlledBackend backend = _ControlledBackend(
        blockFirstCancel: true,
      );
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> first = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'A'),
        stopPrevious: true,
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);

      final Future<AiChatTurnResult> second = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'B'),
        stopPrevious: true,
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );
      final Future<AiChatTurnResult> third = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'C'),
        stopPrevious: true,
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );

      backend.firstCancelGate.complete();
      expect((await first).stopped, isTrue);
      expect((await second).stopped, isTrue);
      await backend.waitForCalls(2);

      expect(
        backend.requests.map((request) => request.history.last.content),
        <String>['A', 'C'],
      );

      backend.streams.last
        ..add(const AiStreamEvent(text: 'done'))
        ..close();
      expect((await third).content, 'done');
      await backend.closeAll();
    },
  );

  test(
    'overlapping deferred turns wait for previous partial history commit',
    () async {
      final _ControlledBackend backend = _ControlledBackend(
        blockFirstCancel: true,
      );
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> first = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'tool A'),
        stopPrevious: true,
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);
      backend.streams[0].add(const AiStreamEvent(text: 'A partial'));
      await Future<void>.delayed(Duration.zero);

      final Future<AiChatTurnResult> second = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'tool B'),
        stopPrevious: true,
        deferHistoryCommit: true,
        onPreview: (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, hasLength(1));

      backend.firstCancelGate.complete();
      await first;
      await backend.waitForCalls(2);

      expect(backend.requests[1].history.map((e) => e.content), <String>[
        'tool A',
        'A partial',
        'tool B',
      ]);

      backend.streams[1]
        ..add(const AiStreamEvent(text: 'B answer'))
        ..close();
      await second;
      expect(session.history.map((e) => e.content), <String>[
        'tool A',
        'A partial',
        'tool B',
        'B answer',
      ]);
      await backend.closeAll();
    },
  );

  test('clear during active turn prevents stale history writes', () async {
    final _ControlledBackend backend = _ControlledBackend(
      blockFirstCancel: true,
    );
    final AiChatSession session = AiChatSession(backend: backend);

    final Future<AiChatTurnResult> running = session.send(
      userMessage: const AiChatHistoryMessage.user(content: 'old'),
      onPreview: (_, _) {},
    );
    await backend.waitForCalls(1);
    backend.streams[0].add(const AiStreamEvent(text: 'partial'));
    await Future<void>.delayed(Duration.zero);

    session.clear();
    expect(session.history, isEmpty);
    backend.firstCancelGate.complete();
    await running;

    expect(session.history, isEmpty);
    await backend.closeAll();
  });

  test(
    'new conversation starts without waiting for old transport cancellation',
    () async {
      final _ControlledBackend backend = _ControlledBackend(
        blockFirstCancel: true,
      );
      final AiChatSession session = AiChatSession(backend: backend);

      final Future<AiChatTurnResult> oldTurn = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'old'),
        onPreview: (_, _) {},
      );
      await backend.waitForCalls(1);

      session.clear();
      final Future<AiChatTurnResult> newTurn = session.send(
        userMessage: const AiChatHistoryMessage.user(content: 'new'),
        onPreview: (_, _) {},
      );

      // clear() gives the new generation an independent Turn chain.
      await backend.waitForCalls(2);
      expect(backend.requests[1].history.map((e) => e.content), <String>[
        'new',
      ]);

      backend.streams[1]
        ..add(const AiStreamEvent(text: 'new answer'))
        ..close();
      await newTurn;

      backend.firstCancelGate.complete();
      await oldTurn;
      expect(session.history.map((e) => e.content), <String>[
        'new',
        'new answer',
      ]);
      await backend.closeAll();
    },
  );
}
