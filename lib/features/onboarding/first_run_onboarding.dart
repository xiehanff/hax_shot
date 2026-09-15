import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导是否已经展示过。
///
/// HaxShot 是托盘/菜单栏应用：第一次双击打开时屏幕上什么都不出现，新用户很容易
/// 以为没启动。所以首次运行弹一次欢迎窗口，说明图标在哪、快捷键是什么。
///
/// 这里的偏好读写和 `MacosShortcutService` 一样必须有上限：`SharedPreferences`
/// 底层是 `NSUserDefaults`，坏掉的 domain（plist 被 `rm` 删掉）会让它**永远不返回**。
/// 欢迎页排在启动链最后，但挂在它上面会让 `desktop_init_complete` 永远不出现，
/// 排查“快捷键没反应”时就少了一条“启动链走完了”的证据。
final class FirstRunOnboarding {
  FirstRunOnboarding({
    this.storeKey = defaultStoreKey,
    this.timeout = _defaultTimeout,
  });

  static const defaultStoreKey = 'hax_shot.onboarding_seen';

  static const _defaultTimeout = Duration(seconds: 2);

  static final instance = FirstRunOnboarding();

  final String storeKey;
  final Duration timeout;

  /// 读取失败/超时一律当成“没看过”：多弹一次欢迎窗口，好过永远卡在这里。
  Future<bool> hasSeen() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        timeout,
      );
      return preferences.getBool(storeKey) ?? false;
    } on Object catch (error) {
      debugPrint('读取欢迎页标记失败（当成没看过）：$error');
      return false;
    }
  }

  /// 标记为已展示。按 hax_pick 的做法：展示时立刻记，避免用户刚看到就退出后
  /// 每次启动都再弹一次。
  Future<void> markSeen() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        timeout,
      );
      await preferences.setBool(storeKey, true);
    } on Object catch (error) {
      // 记不下来只会让下次启动再弹一次，不影响截图和快捷键。
      debugPrint('保存欢迎页标记失败：$error');
    }
  }
}
