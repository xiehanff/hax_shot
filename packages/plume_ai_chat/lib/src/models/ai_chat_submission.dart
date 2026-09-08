import 'dart:typed_data';

import '../backend/ai_backend.dart';
import 'ai_chat_history_message.dart';

/// One controller-level chat submission.
///
/// [userMessage] is the prompt/history message sent to the model, while
/// [displayText]/[displayImageBytes] describe what the host wants to show in
/// the conversation UI. They intentionally differ for domain actions where
/// the transport prompt contains rich context but the user should only see a
/// short action label or selected image.
class AiChatSubmission {
  const AiChatSubmission({
    required this.userMessage,
    required this.displayText,
    this.displayImageBytes,
    this.systemPrompt,
    this.options = const AiRequestOptions(),
    this.stopPrevious = false,
    this.deferHistoryCommit = false,
  });

  final AiChatHistoryMessage userMessage;
  final String displayText;
  final Uint8List? displayImageBytes;
  final String? systemPrompt;
  final AiRequestOptions options;
  final bool stopPrevious;
  final bool deferHistoryCommit;
}
