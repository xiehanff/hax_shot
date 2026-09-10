import 'dart:io';

/// macOS 屏幕录制授权的辅助操作。
///
/// 为什么需要「重置记录」：macOS 把授权绑在代码签名上。本地构建是 ad-hoc 签名，
/// 每次重新构建签名指纹都会变，系统设置里那条旧记录（开关看着是开的）就和新
/// 二进制对不上了——既没权限、又因为列表里已有记录而不再弹授权框。这时唯一的
/// 出路是删掉那条记录：`tccutil reset ScreenCapture <bundle id>`，下一次请求
/// 授权就会重新弹系统对话框。
final class ScreenCapturePermission {
  ScreenCapturePermission({
    Future<ProcessResult> Function(String, List<String>)? processRunner,
  }) : _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments));

  static final instance = ScreenCapturePermission();

  /// 必须和 macOS Runner 的 `PRODUCT_BUNDLE_IDENTIFIER` 一致
  /// （见 `macos/Runner/Configs/AppInfo.xcconfig`）。
  static const bundleIdentifier = 'com.github.xiehanff.haxShot';

  final Future<ProcessResult> Function(String, List<String>) _processRunner;

  Future<void> reset() async {
    if (!Platform.isMacOS) return;
    final result = await _processRunner('tccutil', [
      'reset',
      'ScreenCapture',
      bundleIdentifier,
    ]);
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw StateError(
        error.isEmpty ? 'tccutil 退出码 ${result.exitCode}' : error,
      );
    }
  }
}
