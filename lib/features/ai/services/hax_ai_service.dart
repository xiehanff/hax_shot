import 'package:plume_ai_chat/plume_ai_chat.dart';

import '../models/hax_ai_state.dart';
import 'hax_ai_settings_store.dart';

/// Hax Shot 对共享 AI 对话运行时的宿主适配。
///
/// 对话历史、流式状态和请求取消均由 [plume_ai_chat] 持有；本服务只负责
/// DeepSeek 凭据和宿主侧初始化状态。
class HaxAiService {
  HaxAiService({required this._settingsStore}) {
    session = AiChatSession(
      backend: DeepSeekBackend(apiKeyProvider: _provideApiKey),
    );
    chatController = AiChatController(session: session);
  }

  final HaxAiSettingsStore _settingsStore;
  late final AiChatSession session;
  late final AiChatController chatController;

  HaxAiState _state = const HaxAiState(loading: true);
  Future<void>? _initFuture;
  String _apiKey = '';
  bool _apiKeyOverridden = false;
  bool _disposed = false;

  HaxAiState get state => _state;

  /// 初始化凭据。缓存 Future，避免宿主重复初始化时发生竞态。
  Future<void> init() {
    return _initFuture ??= _loadState();
  }

  Future<void> _loadState() async {
    try {
      final String storedApiKey = (await _settingsStore.loadApiKey()).trim();
      if (!_apiKeyOverridden) {
        _apiKey = storedApiKey;
      }
      _state = HaxAiState(apiKey: _apiKey);
    } finally {
      // 即使 SharedPreferences 初始化失败，也不能让 UI 永久停留在 loading。
      _state = _state.copyWith(loading: false);
    }
  }

  String _provideApiKey() => _apiKey;

  /// 更新当前输入中的凭据。持久化仍由 [saveApiKey] 明确完成。
  void updateApiKey(String apiKey) {
    if (_disposed) return;
    _apiKeyOverridden = true;
    _apiKey = apiKey.trim();
    _state = _state.copyWith(apiKey: _apiKey);
  }

  Future<void> saveApiKey(String apiKey) async {
    if (_disposed) return;
    final String value = apiKey.trim();
    await _settingsStore.saveApiKey(value);
    if (_disposed) return;
    _apiKeyOverridden = true;
    _apiKey = value;
    _state = _state.copyWith(apiKey: value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    chatController.onClose();
  }
}
