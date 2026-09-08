import '../models/ai_chat_history_message.dart';

/// Provider-neutral generation options.
///
/// [providerOptions] is intentionally opaque to the core runtime. Concrete
/// backends may read provider-specific fields without leaking them into
/// [AiChatSession].
class AiRequestOptions {
  const AiRequestOptions({
    this.maxOutputTokens,
    this.providerOptions = const <String, Object?>{},
  });

  final int? maxOutputTokens;
  final Map<String, Object?> providerOptions;
}

/// Provider-neutral request passed from the chat runtime to a concrete backend.
///
/// Authentication is owned by the backend implementation/configuration rather
/// than the chat core. A local backend may require no credentials at all, while
/// a remote provider can resolve tokens through an injected callback.
class AiBackendRequest {
  const AiBackendRequest({
    required this.history,
    this.systemPrompt,
    this.options = const AiRequestOptions(),
  });

  final List<AiChatHistoryMessage> history;
  final String? systemPrompt;
  final AiRequestOptions options;
}

/// Provider-neutral streaming event.
class AiStreamEvent {
  const AiStreamEvent({this.text = '', this.reasoning = ''});

  final String text;
  final String reasoning;
}

/// Transport boundary implemented by DeepSeek/OpenAI/Gemini/local models/etc.
abstract interface class AiBackend {
  Stream<AiStreamEvent> chat(AiBackendRequest request);
}
