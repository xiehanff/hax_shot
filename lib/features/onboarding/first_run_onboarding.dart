import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导是否已经展示过。
///
/// Hax Shot 是托盘/菜单栏应用：第一次双击打开时屏幕上什么都不出现，新用户很容易
/// 以为没启动。所以首次运行弹一次欢迎窗口，说明图标在哪、快捷键是什么。
final class FirstRunOnboarding {
  FirstRunOnboarding({this.storeKey = defaultStoreKey});

  static const defaultStoreKey = 'hax_shot.onboarding_seen';

  static final instance = FirstRunOnboarding();

  final String storeKey;

  Future<bool> hasSeen() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(storeKey) ?? false;
  }

  /// 标记为已展示。按 hax_pick 的做法：展示时立刻记，避免用户刚看到就退出后
  /// 每次启动都再弹一次。
  Future<void> markSeen() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(storeKey, true);
  }
}
