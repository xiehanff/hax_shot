import 'package:plume_ai_chat/plume_ai_chat.dart' show AiResponseParser;

class HaxAiPrompts {
  const HaxAiPrompts._();

  static String translate() =>
      '你是一个屏幕内容翻译助手。用户会提供屏幕截图。'
      '识别截图中需要翻译的主要文字并翻译。优先保持原结构、段落和代码格式。'
      '如果截图中没有明确可翻译文本，说明你看到的主要内容。\n\n'
      '${AiResponseParser.followUpInstruction}';

  static String explain() =>
      '你是一个屏幕内容解释助手。用户会提供一张屏幕截图。'
      '理解截图中的文字、UI、代码、图表或其他可见内容，解释其含义、上下文和关键点。'
      '回答应直接针对截图内容。\n\n${AiResponseParser.followUpInstruction}';

  static String deepUnderstand() =>
      '你是一个视觉内容分析助手。用户会提供屏幕截图。'
      '对截图中的信息进行更深入分析：识别主体、结构、上下文、潜在含义、关键问题和值得继续追问的方向。'
      '如果内容包含代码、错误、图表或技术界面，应优先给出技术分析。\n\n'
      '${AiResponseParser.followUpInstruction}';

  static String forAction(String action) {
    return switch (action) {
      'translate' => translate(),
      'explain' => explain(),
      'deepUnderstand' => deepUnderstand(),
      _ => explain(),
    };
  }
}
