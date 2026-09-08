import 'package:shared_preferences/shared_preferences.dart';

class HaxAiSettingsStore {
  static const String _apiKeyStorageKey = 'hax_shot.deepseek_api_key';

  Future<String> loadApiKey() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_apiKeyStorageKey) ?? '';
  }

  Future<void> saveApiKey(String apiKey) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_apiKeyStorageKey, apiKey.trim());
  }
}
