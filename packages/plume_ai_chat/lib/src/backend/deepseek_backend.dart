import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_chat_history_message.dart';
import '../models/ai_chat_input.dart';
import 'ai_backend.dart';

/// DeepSeek OpenAI-compatible streaming backend for generic chat turns.
///
/// Domain-specific prompt construction belongs to the host application. The
/// backend only converts generic chat history and the optional system prompt to
/// DeepSeek's HTTP/SSE protocol. Authentication is resolved by the backend so
/// the provider-neutral chat core never needs to know what an API key is.
class DeepSeekBackend implements AiBackend {
  DeepSeekBackend({
    required FutureOr<String> Function() apiKeyProvider,
    http.Client? httpClient,
    this.model = defaultModel,
    this.endpoint = 'https://api.deepseek.com/v1',
    this.reasoningEffort = 'low',
  }) : _apiKeyProvider = apiKeyProvider,
       _httpClient = httpClient;

  static const String defaultModel = 'deepseek-v4-flash-vision-exp';

  final FutureOr<String> Function() _apiKeyProvider;
  final http.Client? _httpClient;
  final String model;
  final String endpoint;

  /// Default DeepSeek reasoning effort. A request can override this through
  /// `providerOptions['reasoning_effort']`; an explicit null removes the field.
  final String? reasoningEffort;

  @override
  Stream<AiStreamEvent> chat(AiBackendRequest request) async* {
    final String apiKey = (await _apiKeyProvider()).trim();
    if (apiKey.isEmpty) {
      throw const DeepSeekBackendException('请先填写 DeepSeek API Key。');
    }
    if (request.history.isEmpty) {
      throw const DeepSeekBackendException('对话内容不能为空。');
    }

    final Object? requestReasoningEffort =
        request.options.providerOptions.containsKey('reasoning_effort')
        ? request.options.providerOptions['reasoning_effort']
        : reasoningEffort;

    final http.Client client = _httpClient ?? http.Client();
    final bool closeClient = _httpClient == null;
    try {
      final http.Request httpRequest =
          http.Request('POST', Uri.parse('$endpoint/chat/completions'))
            ..headers.addAll(<String, String>{
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            })
            ..body = jsonEncode(<String, dynamic>{
              'model': model,
              'messages': _messages(request),
              'stream': true,
              if (request.options.maxOutputTokens != null)
                'max_tokens': request.options.maxOutputTokens,
              if (requestReasoningEffort is String &&
                  requestReasoningEffort.trim().isNotEmpty)
                'reasoning_effort': requestReasoningEffort,
            });

      final http.StreamedResponse response = await client
          .send(httpRequest)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await response.stream.bytesToString();
        throw DeepSeekBackendException(
          _normalizeError(
            'HTTP ${response.statusCode}: $body',
            statusCode: response.statusCode,
          ),
          statusCode: response.statusCode,
        );
      }

      await for (final String line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) {
          continue;
        }
        final String data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') {
          continue;
        }

        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) {
          continue;
        }
        final Object? rawChoices = decoded['choices'];
        if (rawChoices is! List || rawChoices.isEmpty) {
          continue;
        }
        final Object? rawChoice = rawChoices.first;
        if (rawChoice is! Map<String, dynamic>) {
          continue;
        }
        final Object? rawDelta = rawChoice['delta'];
        if (rawDelta is! Map<String, dynamic>) {
          continue;
        }

        final String reasoning = _firstString(rawDelta, <String>[
          'reasoning_content',
          'reasoning',
          'thinking',
          'thought',
        ]);
        final String text = _stringValue(rawDelta['content']);
        if (reasoning.isNotEmpty || text.isNotEmpty) {
          yield AiStreamEvent(text: text, reasoning: reasoning);
        }
      }
    } on DeepSeekBackendException {
      rethrow;
    } catch (error) {
      throw DeepSeekBackendException(_normalizeError(error.toString()));
    } finally {
      if (closeClient) {
        client.close();
      }
    }
  }

  List<Map<String, dynamic>> _messages(AiBackendRequest request) {
    return <Map<String, dynamic>>[
      if (request.systemPrompt?.trim().isNotEmpty ?? false)
        _textMessage('system', request.systemPrompt!.trim()),
      ...request.history.map(_historyMessage),
    ];
  }

  Map<String, dynamic> _historyMessage(AiChatHistoryMessage message) {
    final AiImageAttachment? image = message.image;
    final bool hasImage = image?.bytes.isNotEmpty ?? false;
    final String role = switch (message.role) {
      AiChatHistoryRole.assistant => 'assistant',
      AiChatHistoryRole.system => 'system',
      AiChatHistoryRole.user => 'user',
    };
    final String text = message.content.trim().isEmpty && hasImage
        ? '请分析这张图片。'
        : message.content;
    if (!hasImage) {
      return _textMessage(role, text);
    }
    return <String, dynamic>{
      'role': role,
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
        <String, dynamic>{
          'type': 'image_url',
          'image_url': <String, dynamic>{
            'url':
                'data:${image!.mimeType};base64,${base64Encode(image.bytes)}',
          },
        },
      ],
    };
  }

  Map<String, dynamic> _textMessage(String role, String text) {
    return <String, dynamic>{'role': role, 'content': text};
  }

  String _firstString(Map<String, dynamic> values, List<String> keys) {
    for (final String key in keys) {
      final String value = _stringValue(values[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _stringValue(Object? value) => value is String ? value : '';

  String _normalizeError(String message, {int? statusCode}) {
    final String lowercased = message.toLowerCase();
    if (statusCode == 401 ||
        lowercased.contains('authentication') ||
        lowercased.contains('api key')) {
      return 'DeepSeek 认证失败：API Key 无效或授权不足。';
    }
    return 'DeepSeek 请求失败：$message';
  }
}

class DeepSeekBackendException implements Exception {
  const DeepSeekBackendException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
