#include "windows_shortcut_bridge.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "hax_shot/shortcut";

/// 旧 SDK 不一定定义 MOD_NOREPEAT（Win7+ 的 winuser.h 有）。
#ifndef MOD_NOREPEAT
#define MOD_NOREPEAT 0x4000
#endif

/// `VK_F12`：系统永远保留给调试器，注册一定会失败（§22），这里提前拒绝并给出原因，
/// 免得用户拿到一个看不懂的 Win32 错误码。
constexpr int32_t kVkF12 = 0x7B;

/// 自有 code：调用线程不是窗口线程。
///
/// `RegisterHotKey(hwnd, ...)` 要求 hwnd 与调用线程同源，否则热键会被绑到一个永远
/// 不会投递消息的窗口上；这条其实不该发生（channel handler 跑在平台线程上，正是
/// 创建窗口的那个线程），所以宁可显式报错，也不要静默注册出一个按了没反应的组合。
/// 复用 Win32 的 ERROR_INVALID_THREAD_ID(1444) 作为 code，文案里写清原因。
constexpr int32_t kErrorWrongThread = ERROR_INVALID_THREAD_ID;

std::string DescribeWin32Error(const char* operation, DWORD code) {
  switch (code) {
    case ERROR_HOTKEY_ALREADY_REGISTERED:
      return "这个组合已经被其它程序占用";
    case ERROR_INVALID_WINDOW_HANDLE:
      return "窗口句柄无效（注册必须发生在创建窗口的那个线程上）";
    case ERROR_ACCESS_DENIED:
      return "系统拒绝了这个组合（可能被系统或其它进程独占）";
    case ERROR_INVALID_PARAMETER:
      return "参数不合法（键码或修饰键被系统拒绝）";
    default:
      return std::string(operation) + " 返回 Win32 错误 " +
             std::to_string(code);
  }
}

/// 与 macOS 桥完全一致的返回形状（§21）。成功时不带 message。
flutter::EncodableMap BuildResult(int32_t code, const std::string& message) {
  flutter::EncodableMap result;
  result[flutter::EncodableValue("ok")] = flutter::EncodableValue(code == 0);
  result[flutter::EncodableValue("osStatus")] = flutter::EncodableValue(code);
  if (code != 0 && !message.empty()) {
    result[flutter::EncodableValue("message")] =
        flutter::EncodableValue(message);
  }
  return result;
}

}  // namespace

WindowsShortcutBridge::WindowsShortcutBridge(flutter::BinaryMessenger* messenger,
                                             HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

WindowsShortcutBridge::~WindowsShortcutBridge() {
  // 窗口销毁 / 进程退出前注销：系统在进程退出时也会释放热键，但不能依赖它——
  // 桥可能在窗口还活着的时候被拆掉（OnDestroy 先 reset 桥再销毁引擎），
  // 那时不注销就会留下一个热键把组合占住。
  DWORD error_code = ERROR_SUCCESS;
  std::string message;
  UnregisterInternal(&error_code, &message);

  // 显式摘掉 handler：MethodChannel 析构不会自动注销，而 handler 捕获了 this，
  // 留在 messenger 里就是悬空回调。
  if (channel_) {
    channel_->SetMethodCallHandler(
        flutter::MethodCallHandler<flutter::EncodableValue>());
  }
}

std::optional<LRESULT> WindowsShortcutBridge::HandleMessage(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  // 只认自己的 id：其它插件的 WM_HOTKEY（各自的 id）一律放行（§23）。
  if (message == WM_HOTKEY && wparam == static_cast<WPARAM>(kHotKeyId)) {
    Fire();
    return 0;
  }
  return std::nullopt;
}

void WindowsShortcutBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  if (method == "register") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args == nullptr) {
      result->Success(BuildResult(
          ERROR_INVALID_PARAMETER, "register 需要 {keyCode, modifiers} 参数"));
      return;
    }

    // §8.7：MethodChannel 的整数可能是 int32 也可能是 int64，必须用
    // TryGetLongValue 同时接受两者；用 std::get<int> 在类型不匹配时不是抛异常而是
    // 直接终止进程（runner 编译时带 _HAS_EXCEPTIONS=0）。
    const auto key_it = args->find(flutter::EncodableValue("keyCode"));
    if (key_it == args->end()) {
      result->Success(
          BuildResult(ERROR_INVALID_PARAMETER, "register 缺少 keyCode"));
      return;
    }
    const std::optional<int64_t> key_value = key_it->second.TryGetLongValue();
    if (!key_value.has_value() || *key_value <= 0 || *key_value > 0xFF) {
      result->Success(BuildResult(
          ERROR_INVALID_PARAMETER,
          "keyCode 越界（需要 1..255 的 Windows 虚拟键码 VK_*）"));
      return;
    }
    const int virtual_key_code = static_cast<int>(*key_value);
    if (virtual_key_code == kVkF12) {
      result->Success(BuildResult(
          ERROR_INVALID_PARAMETER,
          "F12 由系统保留给调试器，不能注册为全局快捷键"));
      return;
    }

    // 修饰键名 → MOD_* 位。名字集合与 macOS 桥一致（alt / control / shift /
    // meta），因为 Dart 侧共用同一份绑定串解析。
    DWORD modifiers = 0;
    const auto modifiers_it = args->find(flutter::EncodableValue("modifiers"));
    if (modifiers_it != args->end()) {
      const auto* list =
          std::get_if<flutter::EncodableList>(&modifiers_it->second);
      if (list != nullptr) {
        for (const flutter::EncodableValue& item : *list) {
          const auto* name = std::get_if<std::string>(&item);
          if (name == nullptr) {
            result->Success(BuildResult(ERROR_INVALID_PARAMETER,
                                        "modifiers 里出现了非字符串项"));
            return;
          }
          if (*name == "alt" || *name == "option") {
            modifiers |= MOD_ALT;
          } else if (*name == "control" || *name == "ctrl") {
            modifiers |= MOD_CONTROL;
          } else if (*name == "shift") {
            modifiers |= MOD_SHIFT;
          } else if (*name == "meta" || *name == "super" ||
                     *name == "command" || *name == "cmd") {
            modifiers |= MOD_WIN;
          } else {
            // 不能忽略：少一个修饰键会注册出一个比用户预期弱的组合
            // （Alt+Shift+Z 变成 Shift+Z），比直接报错危险得多。
            result->Success(BuildResult(
                ERROR_INVALID_PARAMETER, "原生桥不认识这个修饰键：" + *name));
            return;
          }
        }
      }
    }
    if (modifiers == 0) {
      result->Success(BuildResult(ERROR_INVALID_PARAMETER,
                                  "至少需要一个修饰键（Alt / Ctrl / Shift / Win）"));
      return;
    }

    Register(virtual_key_code, modifiers, std::move(result));
    return;
  }
  if (method == "unregister") {
    Unregister(std::move(result));
    return;
  }
  result->NotImplemented();
}

void WindowsShortcutBridge::Register(
    int virtual_key_code,
    DWORD modifiers,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (window_ == nullptr) {
    result->Success(
        BuildResult(ERROR_INVALID_WINDOW_HANDLE, "浮层/主窗口句柄还没建好"));
    return;
  }
  const DWORD window_thread = ::GetWindowThreadProcessId(window_, nullptr);
  if (window_thread != ::GetCurrentThreadId()) {
    result->Success(BuildResult(
        kErrorWrongThread,
        "注册必须在创建窗口的那个线程上调用（窗口线程 " +
            std::to_string(window_thread) + "，当前线程 " +
            std::to_string(::GetCurrentThreadId()) + "）"));
    return;
  }

  // 同一个 HWND/id 的旧注册仍然有效，`RegisterHotKey` 不会自动替换，必须先注销（§22）。
  // 注销失败就中止：不知道旧注册还在不在，就不能再叠一个新的上去。
  DWORD error_code = ERROR_SUCCESS;
  std::string message;
  if (!UnregisterInternal(&error_code, &message)) {
    result->Success(BuildResult(
        static_cast<int32_t>(error_code),
        "重新注册前注销旧注册失败：" + message));
    return;
  }

  // MOD_NOREPEAT：按住不放不会连发（§22）。没有它长按快捷键会连开好几个截图进程。
  ::SetLastError(ERROR_SUCCESS);
  const BOOL ok = ::RegisterHotKey(window_, kHotKeyId,
                                   modifiers | MOD_NOREPEAT, virtual_key_code);
  if (ok == FALSE) {
    // 这里才是「注册成功」的唯一判据：返回 zero + GetLastError()（§22）。
    const DWORD win32_error = ::GetLastError();
    result->Success(BuildResult(static_cast<int32_t>(win32_error),
                                DescribeWin32Error("RegisterHotKey",
                                                   win32_error)));
    return;
  }
  registered_ = true;
  result->Success(BuildResult(0, std::string()));
}

void WindowsShortcutBridge::Unregister(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  DWORD error_code = ERROR_SUCCESS;
  std::string message;
  if (!UnregisterInternal(&error_code, &message)) {
    result->Success(BuildResult(static_cast<int32_t>(error_code), message));
    return;
  }
  result->Success(BuildResult(0, std::string()));
}

bool WindowsShortcutBridge::UnregisterInternal(DWORD* error_code,
                                               std::string* message) {
  if (!registered_) {
    return true;
  }
  if (window_ == nullptr) {
    // 窗口已经没了：系统会把该窗口的热键一起释放，这里只需要丢掉标记。
    registered_ = false;
    return true;
  }
  ::SetLastError(ERROR_SUCCESS);
  if (::UnregisterHotKey(window_, kHotKeyId) == FALSE) {
    // 不能清 registered_：注销没成功说明它可能还活着，Dart 侧需要据此重试，
    // 否则会出现「配置里没有、系统里还占着这个组合」。
    *error_code = ::GetLastError();
    *message = DescribeWin32Error("UnregisterHotKey", *error_code);
    return false;
  }
  registered_ = false;
  return true;
}

void WindowsShortcutBridge::Fire() {
  // 不走这里起截图进程（§21）：只回调 Dart，由 Dart 的 CaptureLauncher 统一
  // 生成 requestId、写 ACK、记日志，保持触发链只有一条。
  if (channel_) {
    channel_->InvokeMethod("triggered",
                           std::make_unique<flutter::EncodableValue>());
  }
}
