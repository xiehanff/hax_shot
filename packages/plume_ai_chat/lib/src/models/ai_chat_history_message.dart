import 'ai_chat_input.dart';

enum AiChatHistoryRole { user, assistant, system }

class AiChatHistoryMessage {
  const AiChatHistoryMessage.user({required this.content, this.image})
    : role = AiChatHistoryRole.user;

  const AiChatHistoryMessage.assistant({required this.content})
    : role = AiChatHistoryRole.assistant,
      image = null;

  const AiChatHistoryMessage.system({required this.content})
    : role = AiChatHistoryRole.system,
      image = null;

  final AiChatHistoryRole role;
  final String content;
  final AiImageAttachment? image;
}
