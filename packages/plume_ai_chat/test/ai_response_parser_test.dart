import 'package:flutter_test/flutter_test.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

void main() {
  test('extracts follow-up suggestions from streamed response', () {
    final AiResponse response = AiResponseParser.parse('''
正文
<plume_follow_up_suggestions>
["继续解释", "给一个例子"]
</plume_follow_up_suggestions>
''');

    expect(response.content, '正文');
    expect(response.followUpSuggestions, <String>['继续解释', '给一个例子']);
  });

  test('hides incomplete suggestion tag during streaming', () {
    final AiResponse response = AiResponseParser.parse(
      '正文<plume_follow_up_sug',
    );

    expect(response.content, '正文');
    expect(response.followUpSuggestions, isEmpty);
  });
}
