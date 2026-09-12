enum HaxAiAction { translate, explain, deepUnderstand }

extension HaxAiActionLabel on HaxAiAction {
  String get label => switch (this) {
    HaxAiAction.translate => '翻译截图',
    HaxAiAction.explain => '解释截图',
    HaxAiAction.deepUnderstand => '深入理解截图',
  };
}
