import 'package:flutter_test/flutter_test.dart';
import 'package:hax_shot/features/onboarding/first_run_onboarding.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('首次启动标记只影响一次引导', () async {
    SharedPreferences.setMockInitialValues({});
    final onboarding = FirstRunOnboarding(storeKey: 'test.onboarding_seen');

    expect(await onboarding.hasSeen(), isFalse);
    await onboarding.markSeen();
    expect(await onboarding.hasSeen(), isTrue);
  });

  test('默认 key 与实现保持一致', () {
    expect(FirstRunOnboarding.defaultStoreKey, 'hax_shot.onboarding_seen');
  });
}
