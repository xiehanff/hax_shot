import 'dart:typed_data';

class AiChatInput {
  const AiChatInput({this.text = '', this.image});

  final String text;
  final AiImageAttachment? image;

  bool get isEmpty => text.trim().isEmpty && (image?.bytes.isEmpty ?? true);
}

class AiImageAttachment {
  const AiImageAttachment({
    required this.bytes,
    required this.mimeType,
    this.label,
    this.sourcePath,
  });

  final Uint8List bytes;
  final String mimeType;
  final String? label;
  final String? sourcePath;
}
