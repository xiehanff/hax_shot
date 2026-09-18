#ifndef RUNNER_WINDOWS_SHORTCUT_BRIDGE_H_
#define RUNNER_WINDOWS_SHORTCUT_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

/// Windows 全局快捷键桥（§19–§23）：`RegisterHotKey` / `UnregisterHotKey` 的
/// **真实返回值** + `WM_HOTKEY` 转发。
///
/// 为什么不用 `hotkey_manager_windows`：它的 `RegisterHotKey(...)` 返回值直接丢掉，
/// 然后无条件 `result->Success(true)`（§20）。于是「系统拒绝了这个组合」和「注册成功」
/// 在 Dart 侧一模一样，设置页显示“已启用”而按下毫无反应——正是要消灭的故障。
///
/// 这里只做三件事，不含任何快捷键业务逻辑（注册状态机 / 改绑事务 / 回滚都在 Dart 的
/// `WindowsShortcutService` 里）：
///
/// 1. `register({keyCode, modifiers})` → 真实 `GetLastError()` 与可读文案；
/// 2. `unregister()` → 真实 `UnregisterHotKey` 结果；
/// 3. 命中自己的 `WM_HOTKEY` 时通过 `triggered` 回调 Dart。
///
/// **原生层不启动截图**（§21）：触发只回调 Dart，由 Dart 走 `CaptureLauncher`，
/// 保证 requestId / ACK / 日志只有一条链路。
///
/// channel 名与返回形状与 macOS 完全一致（`hax_shot/shortcut`、`{ok, osStatus,
/// message}`），平台互斥不会冲突；但 keyCode 的含义**不同**：这里是 Windows 虚拟键码
/// （`VK_*`），不是 Carbon 键码，也不是 USB HID usage（§25.2）。
class WindowsShortcutBridge {
 public:
  /// 固定的 hotkey id（'HA'）。
  ///
  /// `WM_HOTKEY` 的 wParam 只带 id，不带别的东西，所以「是不是自己的热键」全靠它；
  /// 单实例只注册一个快捷键，固定 id 比每次随机生成更容易排查（§21）。
  /// 0xC000–0xFFFF 是留给 DLL 的，这里用 0x4841 不与它们冲突。
  static constexpr int kHotKeyId = 0x4841;

  WindowsShortcutBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsShortcutBridge();

  WindowsShortcutBridge(const WindowsShortcutBridge&) = delete;
  WindowsShortcutBridge& operator=(const WindowsShortcutBridge&) = delete;

  /// 插件 / Flutter 之前的钩子：**只**处理自己的 `WM_HOTKEY`
  /// （`wParam == kHotKeyId`），其余消息一律返回 `std::nullopt` 放行（§23）。
  /// 其它插件注册的热键有它们自己的 id，不会被这里吃掉。
  std::optional<LRESULT> HandleMessage(HWND window,
                                       UINT message,
                                       WPARAM wparam,
                                       LPARAM lparam) noexcept;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  /// `register`：先注销旧注册（同 HWND/id 的旧注册不会自动替换，§22），再注册新的。
  void Register(int virtual_key_code,
                DWORD modifiers,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                    result);

  /// `unregister`：没注册时也算成功（幂等，与 macOS 桥一致）。
  void Unregister(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  /// 注销当前注册；失败时保留 `registered_`（下次还能再试一次注销）。
  bool UnregisterInternal(DWORD* error_code, std::string* message);

  /// 通知 Dart：快捷键被按下（不在这里起截图进程）。
  void Fire();

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  /// 当前是否真的注册着（`RegisterHotKey` 返回 TRUE 才置位）。
  bool registered_ = false;
};

#endif  // RUNNER_WINDOWS_SHORTCUT_BRIDGE_H_
