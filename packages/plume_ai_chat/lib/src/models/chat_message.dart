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
    this.isError = false,
    this.imageBytes,
    this.reasoning,
  });

  final MessageAuthor author;
  final String text;
  final String id;
  final bool isLoading;

  /// 错误占位消息的语义标记（如网络、鉴权失败）。
  ///
  /// 调用方判断「这条是不是错误」只看这个字段，不要再解析 [text] 的文案前缀
  /// （错误占位目前渲染成 `'❌ …'`，那只是观感，不是契约）。
  final bool isError;
  final Uint8List? imageBytes;
  final String? reasoning;
}
