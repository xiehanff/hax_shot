import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

void main() {
  test('serializes generic chat history and parses SSE deltas', () async {
    late Map<String, dynamic> requestBody;
    final MockClient client = MockClient((http.Request request) async {
      requestBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        'data: {"choices":[{"delta":{"reasoning_content":"r","content":"a"}}]}\n\n'
        'data: [DONE]\n\n',
        200,
        headers: <String, String>{'content-type': 'text/event-stream'},
      );
    });
    final DeepSeekBackend backend = DeepSeekBackend(
      apiKeyProvider: () => 'key',
      httpClient: client,
    );

    final List<AiStreamEvent> events = await backend
        .chat(
          const AiBackendRequest(
            systemPrompt: 'system',
            history: <AiChatHistoryMessage>[
              AiChatHistoryMessage.user(content: 'hello'),
            ],
          ),
        )
        .toList();

    expect(requestBody['model'], 'deepseek-v4-flash-vision-exp');
    expect((requestBody['messages'] as List).length, 2);
    expect(events.single.text, 'a');
    expect(events.single.reasoning, 'r');
  });

  test(
    'serializes image attachments without host-domain dependencies',
    () async {
      late Map<String, dynamic> requestBody;
      final MockClient client = MockClient((http.Request request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('data: [DONE]\n\n', 200);
      });
      final DeepSeekBackend backend = DeepSeekBackend(
        apiKeyProvider: () => 'key',
        httpClient: client,
      );

      await backend
          .chat(
            AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(
                  content: 'image',
                  image: AiImageAttachment(
                    bytes: Uint8List.fromList(<int>[1, 2, 3]),
                    mimeType: 'image/png',
                  ),
                ),
              ],
            ),
          )
          .toList();

      final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
      final Map<String, dynamic> user = messages.single as Map<String, dynamic>;
      final List<dynamic> content = user['content'] as List<dynamic>;
      final Map<String, dynamic> image = content[1] as Map<String, dynamic>;
      final Map<String, dynamic> imageUrl =
          image['image_url'] as Map<String, dynamic>;
      expect(imageUrl['url'], 'data:image/png;base64,AQID');
    },
  );

  test(
    'request options can set max tokens and explicitly omit reasoning effort',
    () async {
      late Map<String, dynamic> requestBody;
      final MockClient client = MockClient((http.Request request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('data: [DONE]\n\n', 200);
      });
      final DeepSeekBackend backend = DeepSeekBackend(
        apiKeyProvider: () => 'key',
        httpClient: client,
      );

      await backend
          .chat(
            const AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(content: 'deep dive'),
              ],
              options: AiRequestOptions(
                maxOutputTokens: 32768,
                providerOptions: <String, Object?>{'reasoning_effort': null},
              ),
            ),
          )
          .toList();

      expect(requestBody['max_tokens'], 32768);
      expect(requestBody.containsKey('reasoning_effort'), isFalse);
    },
  );

  test(
    'default reasoning effort is used when request does not override it',
    () async {
      late Map<String, dynamic> requestBody;
      final MockClient client = MockClient((http.Request request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('data: [DONE]\n\n', 200);
      });
      final DeepSeekBackend backend = DeepSeekBackend(
        apiKeyProvider: () => 'key',
        httpClient: client,
      );

      await backend
          .chat(
            const AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(content: 'hello'),
              ],
            ),
          )
          .toList();

      expect(requestBody['reasoning_effort'], 'low');
    },
  );

  test('empty API key fails before transport', () async {
    int calls = 0;
    final DeepSeekBackend backend = DeepSeekBackend(
      apiKeyProvider: () => '   ',
      httpClient: MockClient((http.Request request) async {
        calls++;
        return http.Response('data: [DONE]\n\n', 200);
      }),
    );

    await expectLater(
      backend
          .chat(
            const AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(content: 'hello'),
              ],
            ),
          )
          .toList(),
      throwsA(
        isA<DeepSeekBackendException>().having(
          (DeepSeekBackendException error) => error.message,
          'message',
          contains('API Key'),
        ),
      ),
    );
    expect(calls, 0);
  });

  test('401 authentication failure cannot fallback to text', () async {
    final DeepSeekBackend backend = DeepSeekBackend(
      apiKeyProvider: () => 'bad-key',
      httpClient: MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'Invalid API key provided'},
          }),
          401,
        );
      }),
    );

    try {
      await backend
          .chat(
            const AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(content: 'hello'),
              ],
            ),
          )
          .toList();
      fail('expected DeepSeekBackendException');
    } on DeepSeekBackendException catch (error) {
      expect(error.statusCode, 401);
      expect(error.message, contains('认证失败'));
      expect(error.canFallbackToText, isFalse);
    }
  });

  test('400 image capability rejection can fallback to text', () async {
    final DeepSeekBackend backend = DeepSeekBackend(
      apiKeyProvider: () => 'key',
      httpClient: MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'message': 'This model does not support image input',
            },
          }),
          400,
        );
      }),
    );

    try {
      await backend
          .chat(
            AiBackendRequest(
              history: <AiChatHistoryMessage>[
                AiChatHistoryMessage.user(
                  content: 'analyze',
                  image: AiImageAttachment(
                    bytes: Uint8List.fromList(<int>[1]),
                    mimeType: 'image/png',
                  ),
                ),
              ],
            ),
          )
          .toList();
      fail('expected DeepSeekBackendException');
    } on DeepSeekBackendException catch (error) {
      expect(error.statusCode, 400);
      expect(error.canFallbackToText, isTrue);
    }
  });
}
