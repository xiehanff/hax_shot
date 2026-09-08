import 'dart:typed_data';

enum MessageAuthor { human, ai }

/// Presentation-level chat message used by reusable Flutter chat UIs.
///
/// This is intentionally separate from [AiChatHistoryMessage]: transport
/// history and rendered conversation bubbles have different lifecycles during
/// streaming, optimistic input and error presentation.
class ChatMessage {
  const ChatMessage({
    required this.author,
    required this.text,
    required this.id,
    this.isLoading = false,
    this.imageBytes,
    this.reasoning,
  });

  final MessageAuthor author;
  final String text;
  final String id;
  final bool isLoading;
  final Uint8List? imageBytes;
  final String? reasoning;
}
