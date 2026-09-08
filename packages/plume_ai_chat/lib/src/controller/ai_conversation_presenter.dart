import 'dart:collection';
import 'dart:typed_data';

import '../models/chat_message.dart';

enum _ResultUpdateMode { replace, incremental }

/// Framework-independent presentation state for a streaming chat conversation.
///
/// Transport history and rendered bubbles intentionally remain separate:
/// optimistic user input, loading placeholders, partial reasoning and UI errors
/// have presentation lifecycles that should not mutate model history.
class AiConversationPresenter {
  final List<ChatMessage> _messages = <ChatMessage>[];
  late final UnmodifiableListView<ChatMessage> _messageView =
      UnmodifiableListView<ChatMessage>(_messages);
  String? _lastResult;
  String? _lastReasoning;
  int _nextMessageId = 0;

  List<ChatMessage> get messages => _messageView;

  bool get isEmpty => _messages.isEmpty;

  void reset() {
    _messages.clear();
    _lastResult = null;
    _lastReasoning = null;
    // Keep IDs monotonic across conversation resets. Flutter views commonly use
    // them as ValueKeys, so a new conversation must not reuse a key that an old
    // subtree may still be disposing in the same frame.
  }

  /// Adds a user-visible turn without making any assumption about the transport
  /// prompt. Domain adapters may display a short action label while sending a
  /// richer prompt to the model.
  void addUserMessage({required String text, Uint8List? imageBytes}) {
    _lastResult = null;
    _lastReasoning = null;
    _messages.add(
      ChatMessage(
        author: MessageAuthor.human,
        text: text,
        id: _nextId(),
        imageBytes: imageBytes,
      ),
    );
  }

  void ensureLoadingPlaceholder() {
    if (_messages.any(
      (ChatMessage message) =>
          message.author == MessageAuthor.ai && message.isLoading,
    )) {
      return;
    }
    _messages.add(
      ChatMessage(
        author: MessageAuthor.ai,
        text: '',
        id: _nextId(),
        isLoading: true,
      ),
    );
  }

  /// Synchronizes one externally produced streaming snapshot into rendered
  /// messages. Repeated identical snapshots are ignored.
  void syncResponse({
    required bool loading,
    String? result,
    String? reasoning,
    String? errorMessage,
  }) {
    if (loading) {
      ensureLoadingPlaceholder();
    }

    if (errorMessage != null && errorMessage != _lastResult) {
      _lastResult = errorMessage;
      _lastReasoning = null;
      _replaceLoadingOrAdd(author: MessageAuthor.ai, text: '❌ $errorMessage');
      if (!loading) {
        _finishLastAiMessage();
      }
      return;
    }

    if (result != null && result.trim().isNotEmpty && result != _lastResult) {
      _syncResult(result, reasoning: reasoning, loading: loading);
    }

    if (reasoning != null &&
        reasoning.trim().isNotEmpty &&
        reasoning != _lastReasoning) {
      _syncReasoning(reasoning, loading: loading);
    }

    if (!loading) {
      _finishLastAiMessage();
    }
  }

  void _syncResult(String result, {required bool loading, String? reasoning}) {
    final _ResultUpdateMode updateMode = _resultUpdateMode(result);
    _lastResult = result;
    switch (updateMode) {
      case _ResultUpdateMode.replace:
        _replaceLoadingOrAdd(
          author: MessageAuthor.ai,
          text: result,
          reasoning: reasoning,
          isLoading: loading,
        );
      case _ResultUpdateMode.incremental:
        _updateLastAiMessage(result, reasoning: reasoning, isLoading: loading);
    }
  }

  void _syncReasoning(String reasoning, {required bool loading}) {
    _lastReasoning = reasoning;
    final int loadingIndex = _messages.indexWhere(
      (ChatMessage message) =>
          message.author == MessageAuthor.ai && message.isLoading,
    );
    if (loadingIndex >= 0) {
      final ChatMessage previous = _messages[loadingIndex];
      _messages[loadingIndex] = ChatMessage(
        author: MessageAuthor.ai,
        text: previous.text,
        id: previous.id,
        isLoading: loading,
        reasoning: reasoning,
      );
      return;
    }

    final int lastIndex = _messages.length - 1;
    if (lastIndex >= 0 && _messages[lastIndex].author == MessageAuthor.ai) {
      final ChatMessage previous = _messages[lastIndex];
      _messages[lastIndex] = ChatMessage(
        author: MessageAuthor.ai,
        text: previous.text,
        id: previous.id,
        isLoading: previous.isLoading,
        reasoning: reasoning,
      );
      return;
    }

    _messages.add(
      ChatMessage(
        author: MessageAuthor.ai,
        text: '',
        id: _nextId(),
        isLoading: loading,
        reasoning: reasoning,
      ),
    );
  }

  void _finishLastAiMessage() {
    final int lastIndex = _messages.length - 1;
    if (lastIndex < 0 ||
        _messages[lastIndex].author != MessageAuthor.ai ||
        !_messages[lastIndex].isLoading) {
      return;
    }

    final ChatMessage previous = _messages[lastIndex];
    final bool isEmpty =
        previous.text.trim().isEmpty &&
        (previous.reasoning?.trim().isEmpty ?? true);
    if (isEmpty) {
      _messages.removeAt(lastIndex);
      return;
    }

    _messages[lastIndex] = ChatMessage(
      author: MessageAuthor.ai,
      text: previous.text,
      id: previous.id,
      reasoning: previous.reasoning,
    );
  }

  _ResultUpdateMode _resultUpdateMode(String result) {
    final String? previousResult = _lastResult;
    if (previousResult != null &&
        result.length > previousResult.length &&
        result.startsWith(previousResult)) {
      return _ResultUpdateMode.incremental;
    }
    return _ResultUpdateMode.replace;
  }

  void _replaceLoadingOrAdd({
    required MessageAuthor author,
    required String text,
    String? reasoning,
    bool isLoading = false,
  }) {
    final int loadingIndex = _messages.indexWhere(
      (ChatMessage message) =>
          message.author == MessageAuthor.ai && message.isLoading,
    );
    if (loadingIndex >= 0) {
      final ChatMessage loadingMessage = _messages[loadingIndex];
      _messages[loadingIndex] = ChatMessage(
        author: author,
        text: text,
        id: loadingMessage.id,
        isLoading: isLoading,
        reasoning: reasoning,
      );
      return;
    }
    _updateLastAiMessage(text, reasoning: reasoning, isLoading: isLoading);
  }

  void _updateLastAiMessage(String text, {String? reasoning, bool? isLoading}) {
    final int lastIndex = _messages.length - 1;
    if (lastIndex >= 0 && _messages[lastIndex].author == MessageAuthor.ai) {
      final ChatMessage previous = _messages[lastIndex];
      _messages[lastIndex] = ChatMessage(
        author: MessageAuthor.ai,
        text: text,
        id: previous.id,
        isLoading: isLoading ?? previous.isLoading,
        reasoning: reasoning ?? previous.reasoning,
      );
      return;
    }

    _messages.add(
      ChatMessage(
        author: MessageAuthor.ai,
        text: text,
        id: _nextId(),
        isLoading: isLoading ?? false,
        reasoning: reasoning,
      ),
    );
  }

  String _nextId() => 'msg_${_nextMessageId++}';
}
