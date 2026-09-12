import 'package:get/get.dart';

import '../backend/ai_backend.dart';
import '../core/ai_chat_session.dart';
import '../core/ai_response_parser.dart';
import '../models/ai_chat_history_message.dart';
import '../models/ai_chat_input.dart';
import '../models/ai_chat_submission.dart';
import '../models/chat_message.dart';
import 'ai_conversation_presenter.dart';

abstract final class AiChatUpdateId {
  static const String messages = 'messages';
  static const String status = 'status';
  static const String input = 'input';
  static const String suggestions = 'suggestions';
}

/// GetX controller for the reusable chat UI layer.
///
/// The host app owns creation/lifecycle and passes the controller to widgets.
/// The package does not require Get.put/Get.find or GetX routing.
class AiChatController extends GetxController {
  AiChatController({
    required AiChatSession session,
    AiConversationPresenter? presenter,
  }) : _session = session,
       _presenter = presenter ?? AiConversationPresenter();

  static const AiChatTurnResult _stoppedBeforeTransport = AiChatTurnResult(
    content: '',
    reasoning: '',
    stopped: true,
  );

  final AiChatSession _session;
  final AiConversationPresenter _presenter;

  bool _isGenerating = false;
  String _streamingText = '';
  String _streamingReasoning = '';
  List<String> _followUpSuggestions = const <String>[];
  int _latestSendId = 0;

  bool get isGenerating => _isGenerating;
  String get streamingText => _streamingText;
  String get streamingReasoning => _streamingReasoning;
  List<String> get followUpSuggestions => _followUpSuggestions;
  List<AiChatHistoryMessage> get history => _session.history;
  List<ChatMessage> get messages => _presenter.messages;

  /// Convenience API for a normal user chat message, where UI presentation and
  /// transport history are the same message.
  Future<AiChatTurnResult> send({
    required AiChatInput input,
    String? systemPrompt,
    AiRequestOptions options = const AiRequestOptions(),
    bool stopPrevious = false,
    bool deferHistoryCommit = false,
  }) {
    if (input.isEmpty) {
      return Future<AiChatTurnResult>.value(
        const AiChatTurnResult(content: '', reasoning: ''),
      );
    }

    final String displayText = input.text.trim().isEmpty && input.image != null
        ? '请分析这张图片。'
        : input.text.trim();
    return submit(
      submission: AiChatSubmission(
        userMessage: AiChatHistoryMessage.user(
          content: displayText,
          image: input.image,
        ),
        displayText: displayText,
        displayImageBytes: input.image?.bytes,
        systemPrompt: systemPrompt,
        options: options,
        stopPrevious: stopPrevious,
        deferHistoryCommit: deferHistoryCommit,
      ),
    );
  }

  /// Executes a generic chat turn whose transport prompt may differ from the
  /// text/image presented in the conversation UI.
  Future<AiChatTurnResult> submit({
    required AiChatSubmission submission,
  }) async {
    if (_isGenerating && !submission.stopPrevious) {
      return const AiChatTurnResult(content: '', reasoning: '');
    }

    // `Stop` and latest-wins have different boundary semantics. A user Stop
    // must not discard a response whose transport already completed, whereas a
    // new latest-wins turn must always take presentation ownership and remove
    // the old placeholder even if that old transport is no longer cancellable.
    if (_isGenerating && submission.stopPrevious) {
      if (!stop()) {
        _supersedeCurrentPresentation();
      }
    }

    final int sendId = ++_latestSendId;
    _presenter
      ..addUserMessage(
        text: submission.displayText,
        imageBytes: submission.displayImageBytes,
      )
      ..ensureLoadingPlaceholder();

    _isGenerating = true;
    _streamingText = '';
    _streamingReasoning = '';
    _followUpSuggestions = const <String>[];
    _notifyConversationChanged();

    try {
      if (sendId != _latestSendId) {
        return _stoppedBeforeTransport;
      }

      final AiChatTurnResult result = await _sendSubmission(
        sendId: sendId,
        submission: submission,
      );
      if (sendId == _latestSendId) {
        _streamingText = result.content;
        _streamingReasoning = result.reasoning;
        _followUpSuggestions = result.followUpSuggestions;
        _presenter.syncResponse(
          loading: false,
          result: result.content,
          reasoning: result.reasoning,
        );
      }
      return result;
    } catch (error) {
      // Stop/new-conversation/latest-wins already revoked this turn's
      // presentation ownership. A later transport failure is therefore stale
      // cancellation fallout, not a new error the caller should have to handle.
      if (sendId != _latestSendId) {
        return _stoppedBeforeTransport;
      }
      _presenter.syncResponse(loading: false, errorMessage: error.toString());
      rethrow;
    } finally {
      if (sendId == _latestSendId) {
        _isGenerating = false;
        _notifyConversationChanged();
      }
    }
  }

  Future<AiChatTurnResult> _sendSubmission({
    required int sendId,
    required AiChatSubmission submission,
  }) {
    return _session.send(
      userMessage: submission.userMessage,
      systemPrompt: submission.systemPrompt,
      options: submission.options,
      stopPrevious: submission.stopPrevious,
      deferHistoryCommit: submission.deferHistoryCommit,
      onPreview: (String text, String reasoning) {
        if (sendId != _latestSendId) {
          return;
        }
        final AiResponse response = AiResponseParser.parse(text);
        _streamingText = response.content;
        _streamingReasoning = reasoning;
        _followUpSuggestions = response.followUpSuggestions;
        _presenter.syncResponse(
          loading: true,
          result: response.content,
          reasoning: reasoning,
        );
        update(<String>[AiChatUpdateId.messages, AiChatUpdateId.suggestions]);
      },
    );
  }

  /// Stops the active transport turn owned by this controller.
  ///
  /// Once control is inside [AiChatSession], a false `stopActiveTurn()` means
  /// transport has already crossed its cancellable boundary; in that completion
  /// window we leave ownership intact so the Session's final result cannot be
  /// accidentally discarded.
  bool stop() {
    if (!_isGenerating) {
      return false;
    }

    final bool stopped = _session.stopActiveTurn();
    if (!stopped) {
      return false;
    }
    _finalizeCurrentPresentation();
    return true;
  }

  /// Latest-wins is stronger than Stop: the newly requested turn must own the
  /// message list even when the old Session crossed its cancellation boundary.
  void _supersedeCurrentPresentation() {
    _finalizeCurrentPresentation();
  }

  void _finalizeCurrentPresentation() {
    _latestSendId++;
    _isGenerating = false;
    _followUpSuggestions = const <String>[];
    _presenter.syncResponse(
      loading: false,
      result: _streamingText,
      reasoning: _streamingReasoning,
    );
    _notifyConversationChanged();
  }

  void newConversation() {
    _resetConversation(notify: true);
  }

  @override
  void onClose() {
    // Controller disposal owns the runtime lifecycle too: no network stream or
    // pending turn may outlive a host-owned GetX controller.
    _resetConversation(notify: false);
    super.onClose();
  }

  void _resetConversation({required bool notify}) {
    _latestSendId++;
    _session.clear();
    _presenter.reset();
    _isGenerating = false;
    _streamingText = '';
    _streamingReasoning = '';
    _followUpSuggestions = const <String>[];
    if (notify) {
      _notifyConversationChanged();
    }
  }

  void _notifyConversationChanged() {
    update(<String>[
      AiChatUpdateId.messages,
      AiChatUpdateId.status,
      AiChatUpdateId.input,
      AiChatUpdateId.suggestions,
    ]);
  }
}
