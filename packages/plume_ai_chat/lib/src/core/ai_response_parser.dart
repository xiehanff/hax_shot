import 'dart:convert';

class AiResponse {
  const AiResponse({required this.content, required this.followUpSuggestions});

  final String content;
  final List<String> followUpSuggestions;
}

class AiResponseParser {
  const AiResponseParser._();

  static const String suggestionsStartTag = '<plume_follow_up_suggestions>';
  static const String suggestionsEndTag = '</plume_follow_up_suggestions>';

  static const String followUpInstruction =
      '回答正文完成后，必须根据本轮问题、回答内容、页面上下文和已有对话历史，'
      '生成 2-4 个自然且具体的后续提问或操作建议。建议必须与上下文相关，'
      '不要使用固定模板，不要重复用户已经提出的问题，每条建议尽量简短。'
      '建议不要混入回答正文，必须严格放在以下标记中，标记内容只允许是 JSON 字符串数组：\n'
      '$suggestionsStartTag\n'
      '["建议一", "建议二", "建议三"]\n'
      '$suggestionsEndTag';

  static String chatSystemPrompt() {
    return '你是一个有上下文记忆的 AI 助手。请结合当前对话历史准确回答用户问题，'
        '使用简体中文和清晰的 Markdown；不要复述无关上下文。\n$followUpInstruction';
  }

  static AiResponse parse(String raw) {
    final int startIndex = raw.indexOf(suggestionsStartTag);
    if (startIndex < 0) {
      return AiResponse(
        content: _removeIncompleteStartTag(raw),
        followUpSuggestions: const <String>[],
      );
    }

    final int suggestionsStart = startIndex + suggestionsStartTag.length;
    final int endIndex = raw.indexOf(suggestionsEndTag, suggestionsStart);
    final String content = raw.substring(0, startIndex).trimRight();
    if (endIndex < 0) {
      return AiResponse(
        content: content,
        followUpSuggestions: const <String>[],
      );
    }

    return AiResponse(
      content: content,
      followUpSuggestions: _parseSuggestions(
        raw.substring(suggestionsStart, endIndex),
      ),
    );
  }

  static String _removeIncompleteStartTag(String raw) {
    for (int length = suggestionsStartTag.length - 1; length >= 8; length--) {
      final String partialTag = suggestionsStartTag.substring(0, length);
      final int partialIndex = raw.lastIndexOf(partialTag);
      if (partialIndex >= 0 && partialIndex + partialTag.length == raw.length) {
        return raw.substring(0, partialIndex).trimRight();
      }
    }
    return raw.trim();
  }

  static List<String> _parseSuggestions(String raw) {
    final String normalized = raw.trim();
    if (normalized.isEmpty) {
      return const <String>[];
    }

    final Object? decoded = _tryDecodeJson(normalized);
    if (decoded is List) {
      return _normalizeSuggestions(decoded);
    }
    if (decoded is Map && decoded['suggestions'] is List) {
      return _normalizeSuggestions(decoded['suggestions'] as List);
    }

    return _normalizeSuggestions(normalized.split(RegExp(r'\r?\n')));
  }

  static Object? _tryDecodeJson(String value) {
    final String candidate = value
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    try {
      return jsonDecode(candidate);
    } on FormatException {
      return null;
    }
  }

  static List<String> _normalizeSuggestions(Iterable<Object?> values) {
    final List<String> suggestions = <String>[];
    for (final Object? value in values) {
      final String suggestion = value is String
          ? value.trim()
          : value?.toString().trim() ?? '';
      final String normalized = suggestion
          .replaceFirst(RegExp(r'^(?:[-*•]|\d+[.)])\s+'), '')
          .trim();
      if (normalized.isEmpty || suggestions.contains(normalized)) {
        continue;
      }
      suggestions.add(normalized);
      if (suggestions.length == 5) {
        break;
      }
    }
    return List<String>.unmodifiable(suggestions);
  }
}
