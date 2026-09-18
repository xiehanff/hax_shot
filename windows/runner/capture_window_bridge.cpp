#include "capture_window_bridge.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "hax_shot/capture_window";
constexpr wchar_t kNativeLibraryFileName[] = L"hax_shot_native.dll";

// §8.4 的错误码（与 rust/src/windows.rs 同一套，便于 Dart / C++ 两边都读）。
constexpr int32_t kMonitorOk = 0;
constexpr int32_t kMonitorStale = 5;
constexpr int32_t kMonitorInvalidArgument = 6;
constexpr int32_t kMonitorNotImplemented = 7;

/// 读冻结节目标元数据的导出（§8.4）。摆浮层只能用这一个：它读的是本进程最近一次
/// 成功抓屏**冻结**下来的目标，不重新枚举、不重新读鼠标（§8.5）。
using LastCaptureTargetFn = int32_t (*)(HaxShotTargetMonitor* out);
/// 可读错误文本（跨平台导出）。
using LastErrorFn = size_t (*)(uint8_t* buffer, size_t capacity);

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr,
                                         0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        result.data(), size, nullptr, nullptr);
  return result;
}

/// exe 所在目录（绝对路径）。拿不到时返回空串，由调用方报“找不到 DLL 的候选路径”。
std::wstring ExecutableDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return std::wstring();
  }
  path.resize(length);
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, separator);
}

/// 读 hax_shot_last_error()，失败时退化成带 native code 的固定文本。
std::string ReadNativeError(LastErrorFn last_error,
                            const char* operation,
                            int32_t code) {
  std::string text;
  if (last_error != nullptr) {
    std::vector<uint8_t> buffer(1024, 0);
    last_error(buffer.data(), buffer.size());
    // 返回值含终止 NUL；缓冲不够或被截断时都按第一个 NUL 截断。
    const size_t limit = buffer.size() - 1;
    text.assign(reinterpret_cast<const char*>(buffer.data()), limit);
    const size_t terminator = text.find('\0');
    if (terminator != std::string::npos) {
      text.resize(terminator);
    }
  }
  if (text.empty()) {
    text = std::string(operation) + " 失败（native code " +
           std::to_string(code) + "）";
  }
  return text;
}

/// Rust 原生库的只读元数据接口（§6.10 / §8.4）。
///
/// 用 exe 目录的**绝对路径** + LoadLibraryExW + GetProcAddress 动态加载：不依赖当前
/// 目录 / PATH，也不做静态导入（静态导入失败进程根本起不来，Dart 的分层诊断就没机会
/// 跑）。缺主 DLL、缺依赖 DLL、符号缺失三种情况分别给出候选路径与可读原因。
class NativeTargetApi {
 public:
  static NativeTargetApi& Instance() {
    static NativeTargetApi api;
    return api;
  }

  /// 读本进程最近一次成功抓屏冻结的目标元数据，返回 §8.4 的错误码。
  int32_t ReadLastCaptureTarget(HaxShotTargetMonitor* out, std::string* error) {
    if (!EnsureLoaded(error)) {
      return kMonitorNotImplemented;
    }
    HaxShotTargetMonitor monitor = {};
    const int32_t code = last_capture_target_(&monitor);
    if (code != kMonitorOk) {
      *error = ReadNativeError(last_error_, "hax_shot_last_capture_target",
                               code);
      return code;
    }
    *out = monitor;
    return kMonitorOk;
  }

 private:
  NativeTargetApi() = default;

  bool EnsureLoaded(std::string* error) {
    if (loaded_once_) {
      if (module_ == nullptr) {
        *error = load_error_;
        return false;
      }
      return true;
    }
    loaded_once_ = true;

    const std::wstring directory = ExecutableDirectory();
    if (directory.empty()) {
      load_error_ = "拿不到 exe 目录（GetModuleFileNameW 失败），无法定位 " +
                    ToUtf8(kNativeLibraryFileName);
      *error = load_error_;
      return false;
    }
    const std::wstring path = directory + L"\\" + kNativeLibraryFileName;
    ::SetLastError(ERROR_SUCCESS);
    module_ = ::LoadLibraryExW(
        path.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (module_ == nullptr) {
      const DWORD win32_error = ::GetLastError();
      load_error_ = "加载 " + ToUtf8(path) + " 失败（Win32 错误 " +
                    std::to_string(win32_error) +
                    "）：候选文件不存在，或它缺少依赖 DLL";
      *error = load_error_;
      return false;
    }

    last_capture_target_ =
        reinterpret_cast<LastCaptureTargetFn>(
            ::GetProcAddress(module_, "hax_shot_last_capture_target"));
    last_error_ = reinterpret_cast<LastErrorFn>(
        ::GetProcAddress(module_, "hax_shot_last_error"));
    if (last_capture_target_ == nullptr) {
      load_error_ = "hax_shot_native.dll 已加载（" + ToUtf8(path) +
                    "），但缺少导出 hax_shot_last_capture_target（旧版本 DLL？）";
      ::FreeLibrary(module_);
      module_ = nullptr;
      *error = load_error_;
      return false;
    }
    return true;
  }

  bool loaded_once_ = false;
  std::string load_error_;
  HMODULE module_ = nullptr;
  LastCaptureTargetFn last_capture_target_ = nullptr;
  LastErrorFn last_error_ = nullptr;
};

}  // namespace

CaptureWindowBridge::CaptureWindowBridge(flutter::BinaryMessenger* messenger,
                                         HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

CaptureWindowBridge::~CaptureWindowBridge() {
  // 显式摘掉 handler：MethodChannel 析构不会自动注销，而 handler 捕获了 this，
  // 留在 messenger 里就是悬空回调。
  if (channel_) {
    channel_->SetMethodCallHandler(
        flutter::MethodCallHandler<flutter::EncodableValue>());
  }
}

std::optional<LRESULT> CaptureWindowBridge::HandleMessage(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  // 只拦 bridge 自己拥有的消息：overlay 态的客户区计算（§14.4）。
  // 其余一律返回 nullopt，让 Flutter / 插件 / Win32Window 按原样处理。
  if (message == WM_NCCALCSIZE && wparam == TRUE && overlay_active_ &&
      !restoring_) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    if (params == nullptr) {
      return std::nullopt;
    }
    // 客户区直接等于目标 rcMonitor 的屏幕坐标：不缩 window_manager 的 8 像素，
    // 也不加 Win10 顶部那 1 像素（那些属于 hidden titlebar 分支）。
    params->rgrc[0] = overlay_rect_;
    return 0;
  }
  return std::nullopt;
}

void CaptureWindowBridge::HandleMessageAfterDefault(HWND window,
                                                    UINT message,
                                                    WPARAM wparam,
                                                    LPARAM lparam) noexcept {
  if (message != WM_DPICHANGED || !overlay_active_ || restoring_) {
    return;
  }
  // DPI 已经由默认链路（插件 + Win32Window 的 suggested rect）处理完，这里只负责
  // 最终落位。冻结元数据还在就按它重新钉一次；不在了就保持原 overlay rect 并标
  // 错误态，不撕掉浮层（§14.4）。
  HaxShotTargetMonitor monitor = {};
  std::string error;
  const int32_t code =
      NativeTargetApi::Instance().ReadLastCaptureTarget(&monitor, &error);
  if (code == kMonitorOk && monitor.valid == 1) {
    target_ = monitor;
    overlay_rect_ = {monitor.left, monitor.top, monitor.right, monitor.bottom};
    target_error_code_ = 0;
    target_error_message_.clear();
  } else {
    target_error_code_ = code;
    target_error_message_ = error;
    ::OutputDebugStringA(
        ("hax_shot: overlay target lost during DPI change: " + error + "\n")
            .c_str());
  }

  // 重钉失败时**不得**继续声称 overlay 的物理契约成立（§14.4 / 评审 2）：
  // 记录结构化失败，并通过 `overlayRepinFailed` 事件交给 Dart 决策。
  std::string repin_error;
  DWORD repin_win32_error = ERROR_SUCCESS;
  if (RepinOverlay(&repin_error, &repin_win32_error)) {
    overlay_contract_valid_ = true;
    repin_error_message_.clear();
    repin_win32_error_ = ERROR_SUCCESS;
    return;
  }
  overlay_contract_valid_ = false;
  repin_error_message_ = repin_error;
  repin_win32_error_ = repin_win32_error;
  NotifyRepinFailure(repin_error, repin_win32_error);
}

void CaptureWindowBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  if (method == "becomeOverlay") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args == nullptr) {
      result->Error(std::to_string(kMonitorInvalidArgument),
                    "becomeOverlay 需要 {displayId, generation} 参数");
      return;
    }
    const auto display_it = args->find(flutter::EncodableValue("displayId"));
    if (display_it == args->end()) {
      result->Error(std::to_string(kMonitorInvalidArgument),
                    "becomeOverlay 缺少 displayId");
      return;
    }
    // §8.7：MethodChannel 的整数可能是 int32 也可能是 int64，必须用
    // TryGetLongValue 同时接受两者；用 std::get<int> 在类型不匹配时不是抛异常而是
    // 直接终止进程（runner 编译时带 _HAS_EXCEPTIONS=0）。
    const std::optional<int64_t> display_value =
        display_it->second.TryGetLongValue();
    if (!display_value.has_value() || *display_value < 0 ||
        *display_value > 0xFFFFFFFFll) {
      result->Error(std::to_string(kMonitorInvalidArgument),
                    "displayId 越界（需要 u32；0 表示“未指定”）");
      return;
    }

    uint64_t generation = 0;
    const auto generation_it = args->find(flutter::EncodableValue("generation"));
    if (generation_it != args->end()) {
      const std::optional<int64_t> generation_value =
          generation_it->second.TryGetLongValue();
      if (!generation_value.has_value() || *generation_value < 0) {
        result->Error(std::to_string(kMonitorInvalidArgument),
                      "generation 非法（需要非负整数）");
        return;
      }
      generation = static_cast<uint64_t>(*generation_value);
    }

    BecomeOverlay(static_cast<uint32_t>(*display_value), generation,
                  std::move(result));
    return;
  }
  if (method == "exitOverlay") {
    ExitOverlay(std::move(result));
    return;
  }
  if (method == "enableResizablePanel") {
    // Windows 的普通面板本来就带 WS_THICKFRAME，可缩放由 window_manager 负责
    //（§14.6）；这里保留同名方法，保证 channel 接口与 macOS 一致（§14.8）。
    result->Success();
    return;
  }
  result->NotImplemented();
}

void CaptureWindowBridge::BecomeOverlay(
    uint32_t display_id,
    uint64_t generation,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // 幂等：重复调用直接返回当前状态，不重新快照（否则会丢掉进入前的窗口状态）。
  if (overlay_active_) {
    // 上一次 DPI 变化后重钉失败：物理契约已经失效，不能再用一个“看着成功”的
    // clientRect 回应（§14.4 / 评审 2）。
    if (!overlay_contract_valid_) {
      const std::string detail =
          repin_error_message_.empty()
              ? std::string("没有记录到重钉失败原因（可能是回滚也失败）")
              : repin_error_message_;
      result->Error(
          std::to_string(kMonitorStale),
          "浮层在 DPI 变化后未能重新钉回目标 rcMonitor，物理契约已失效：" +
              detail);
      return;
    }
    result->Success(BuildStatePayload());
    return;
  }
  if (window_ == nullptr || ::IsWindow(window_) == FALSE) {
    result->Error(std::to_string(kMonitorInvalidArgument), "浮层窗口句柄无效");
    return;
  }

  // 1) 只读冻结元数据（§8.5）：不进 fallback、不重新枚举、不重算 rect。
  HaxShotTargetMonitor monitor = {};
  std::string error;
  const int32_t code =
      NativeTargetApi::Instance().ReadLastCaptureTarget(&monitor, &error);
  if (code != kMonitorOk) {
    result->Error(std::to_string(code), error);
    return;
  }
  if (monitor.valid != 1) {
    result->Error(std::to_string(kMonitorStale),
                  "冻结的目标元数据无效（valid=0），本次截图作废");
    return;
  }
  if (monitor.width <= 0 || monitor.height <= 0 ||
      monitor.right <= monitor.left || monitor.bottom <= monitor.top) {
    result->Error(std::to_string(kMonitorStale),
                  "冻结的 rcMonitor 不合理：(" + std::to_string(monitor.left) +
                      "," + std::to_string(monitor.top) + "," +
                      std::to_string(monitor.right) + "," +
                      std::to_string(monitor.bottom) + ")");
    return;
  }
  // 一致性校验（§16.2）：Dart 带的是它请求的那块屏；对不上说明拓扑在抓屏前后变了，
  // 按 §8.9 作废本次截图，不换目标、不退回主屏。
  if (display_id != 0 && display_id != monitor.display_id) {
    result->Error(std::to_string(kMonitorStale),
                  "请求的 display_id=" + std::to_string(display_id) +
                      " 与冻结的 " + std::to_string(monitor.display_id) +
                      " 不一致：屏幕拓扑在抓屏前后变了");
    return;
  }
  if (generation != 0 && generation != monitor.generation) {
    result->Error(std::to_string(kMonitorStale),
                  "请求的 generation=" + std::to_string(generation) +
                      " 与冻结的 " + std::to_string(monitor.generation) +
                      " 不一致");
    return;
  }

  // 2) 快照：必须是“已完成插件初始化的普通窗口”。拿不到就不进 overlay（§14.3）。
  const LONG_PTR style = ::GetWindowLongPtrW(window_, GWL_STYLE);
  if ((style & WS_CAPTION) == 0) {
    result->Error(
        std::to_string(kMonitorInvalidArgument),
        "窗口不是可快照的普通窗口（GWL_STYLE=0x" +
            std::to_string(static_cast<long long>(style)) +
            "），浮层摆位需要窗口已完成插件初始化");
    return;
  }
  RECT window_rect = {0, 0, 0, 0};
  ::GetWindowRect(window_, &window_rect);
  snapshot_.style = style;
  snapshot_.ex_style = ::GetWindowLongPtrW(window_, GWL_EXSTYLE);
  snapshot_.rect = window_rect;
  snapshot_.zoomed = ::IsZoomed(window_) != FALSE;
  snapshot_.topmost = (snapshot_.ex_style & WS_EX_TOPMOST) != 0;
  snapshot_.valid = true;
  target_ = monitor;

  // 3) 异常路径：窗口当前可见时先藏起来，不允许“配置到一半已经在屏幕上”（§14.3）。
  if (::IsWindowVisible(window_) != FALSE) {
    ::ShowWindow(window_, SW_HIDE);
  }

  overlay_rect_ = {monitor.left, monitor.top, monitor.right, monitor.bottom};
  // 从这里开始 WM_NCCALCSIZE 归 bridge 管，直到快照恢复成功（§14.5）。
  overlay_active_ = true;
  overlay_contract_valid_ = false;
  repin_error_message_.clear();
  repin_win32_error_ = ERROR_SUCCESS;

  if (!ApplyOverlayPlacement(&error)) {
    std::string rollback_error;
    if (RestoreSnapshot(&rollback_error)) {
      overlay_active_ = false;
    } else {
      // 回滚也失败时保留 overlay 态：下一次 exitOverlay 还会再试一次恢复（§14.5）。
      error += "；回滚到进入前状态也失败：" + rollback_error;
    }
    result->Error(std::to_string(kMonitorInvalidArgument), error);
    return;
  }

  result->Success(BuildStatePayload());
}

void CaptureWindowBridge::ExitOverlay(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!overlay_active_) {
    // 幂等：不在 overlay 态就是已经退出了（包括进程启动后从没进过）。
    result->Success();
    return;
  }

  std::string error;
  if (!RestoreSnapshot(&error)) {
    // 回读校验失败时重试一次；仍失败就报错，不吞（§14.5）。
    std::string retry_error;
    if (!RestoreSnapshot(&retry_error)) {
      result->Error(std::to_string(kMonitorInvalidArgument),
                    "退出浮层失败：" + retry_error);
      return;
    }
  }

  overlay_active_ = false;
  overlay_contract_valid_ = false;
  snapshot_ = WindowSnapshot();
  target_ = HaxShotTargetMonitor();
  overlay_rect_ = {0, 0, 0, 0};
  target_error_code_ = 0;
  target_error_message_.clear();
  repin_error_message_.clear();
  repin_win32_error_ = ERROR_SUCCESS;
  result->Success();
}

bool CaptureWindowBridge::ApplyOverlayPlacement(std::string* error) {
  // style → WS_POPUP（保留 WS_CLIPCHILDREN / WS_CLIPSIBLINGS），去掉 thickframe /
  // maximizebox 这些属于普通面板的边框位。exStyle 不动：topmost 由 SetWindowPos 设置，
  // WS_EX_LAYERED 等由快照保留（§14.7：Windows 上不再无条件 setOpacity）。
  const LONG_PTR overlay_style = WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS |
                                 (snapshot_.style & WS_DISABLED);
  ::SetLastError(ERROR_SUCCESS);
  ::SetWindowLongPtrW(window_, GWL_STYLE, overlay_style);
  const DWORD style_error = ::GetLastError();
  if (style_error != ERROR_SUCCESS) {
    *error = "设置 WS_POPUP 失败（Win32 错误 " + std::to_string(style_error) +
             "）";
    return false;
  }

  const int width = overlay_rect_.right - overlay_rect_.left;
  const int height = overlay_rect_.bottom - overlay_rect_.top;
  // 只配置、不显示：不带 SWP_SHOWWINDOW，窗口保持隐藏，显示由 Dart 的 showWindow()
  // 唯一负责（§14.3）。
  if (::SetWindowPos(window_, HWND_TOPMOST, overlay_rect_.left,
                     overlay_rect_.top, width, height,
                     SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED) ==
      FALSE) {
    const DWORD win32_error = ::GetLastError();
    *error = "SetWindowPos 到目标 rcMonitor 失败（Win32 错误 " +
             std::to_string(win32_error) + "）";
    return false;
  }

  // 回读校验（§13.5）：窗口 rect、客户区尺寸、以及客户区映射到屏幕后的原点都必须
  // 等于目标 rcMonitor。对不上就报错回滚，不允许“看着差不多”地继续。
  RECT window_rect = {0, 0, 0, 0};
  RECT client_rect = {0, 0, 0, 0};
  POINT client_origin = {0, 0};
  ::GetWindowRect(window_, &window_rect);
  ::GetClientRect(window_, &client_rect);
  ::ClientToScreen(window_, &client_origin);
  if (window_rect.left != overlay_rect_.left ||
      window_rect.top != overlay_rect_.top ||
      window_rect.right != overlay_rect_.right ||
      window_rect.bottom != overlay_rect_.bottom) {
    *error = "浮层窗口 rect 与目标 rcMonitor 不一致：窗口 (" +
             std::to_string(window_rect.left) + "," +
             std::to_string(window_rect.top) + "," +
             std::to_string(window_rect.right) + "," +
             std::to_string(window_rect.bottom) + ") vs 目标 (" +
             std::to_string(overlay_rect_.left) + "," +
             std::to_string(overlay_rect_.top) + "," +
             std::to_string(overlay_rect_.right) + "," +
             std::to_string(overlay_rect_.bottom) + ")";
    return false;
  }
  if (client_rect.right - client_rect.left != width ||
      client_rect.bottom - client_rect.top != height) {
    *error = "浮层客户区尺寸与目标 rcMonitor 不一致：客户区 " +
             std::to_string(client_rect.right - client_rect.left) + "x" +
             std::to_string(client_rect.bottom - client_rect.top) + " vs 目标 " +
             std::to_string(width) + "x" + std::to_string(height) +
             "（WM_NCCALCSIZE 是否被插件 inset？）";
    return false;
  }
  if (client_origin.x != overlay_rect_.left ||
      client_origin.y != overlay_rect_.top) {
    *error = "浮层客户区原点与目标 rcMonitor 不一致：客户区原点 (" +
             std::to_string(client_origin.x) + "," +
             std::to_string(client_origin.y) + ") vs 目标 (" +
             std::to_string(overlay_rect_.left) + "," +
             std::to_string(overlay_rect_.top) + ")";
    return false;
  }
  // 回读全部通过：这一刻物理契约成立。
  overlay_contract_valid_ = true;
  return true;
}

bool CaptureWindowBridge::RestoreSnapshot(std::string* error) {
  if (!snapshot_.valid) {
    *error = "没有可恢复的窗口快照";
    return false;
  }
  if (window_ == nullptr || ::IsWindow(window_) == FALSE) {
    *error = "窗口句柄已经失效，无法恢复";
    return false;
  }

  // 恢复期间的 WM_NCCALCSIZE 交还普通链路：hidden titlebar 的 8 像素 inset 要在
  // 面板态重新生效，不能再按 overlay 的“客户区 = 整块屏”来算。
  restoring_ = true;

  // 顺序：style / exStyle → 窗口 rect → topmost（后两者由同一次 SetWindowPos 完成）。
  ::SetWindowLongPtrW(window_, GWL_STYLE, snapshot_.style);
  ::SetWindowLongPtrW(window_, GWL_EXSTYLE, snapshot_.ex_style);
  const int width =
      snapshot_.rect.right - snapshot_.rect.left;
  const int height = snapshot_.rect.bottom - snapshot_.rect.top;
  const HWND insert_after = snapshot_.topmost ? HWND_TOPMOST : HWND_NOTOPMOST;
  const BOOL positioned =
      ::SetWindowPos(window_, insert_after, snapshot_.rect.left,
                     snapshot_.rect.top, width, height,
                     SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);

  // 回读校验：拿不回原状态就报错，由调用方决定重试（§14.5）。
  bool restored = false;
  if (positioned != FALSE) {
    const LONG_PTR style = ::GetWindowLongPtrW(window_, GWL_STYLE);
    const LONG_PTR ex_style = ::GetWindowLongPtrW(window_, GWL_EXSTYLE);
    RECT rect = {0, 0, 0, 0};
    ::GetWindowRect(window_, &rect);
    const bool rect_ok =
        snapshot_.zoomed
            // 最大化状态只记录、不重放：“重新最大化”只能靠 ShowWindow(SW_MAXIMIZE)，
            // 而那是显示窗口（§14.3 禁止 bridge 显示窗口），所以只校验 style/exStyle。
            ? true
            : (rect.left == snapshot_.rect.left &&
               rect.top == snapshot_.rect.top &&
               rect.right == snapshot_.rect.right &&
               rect.bottom == snapshot_.rect.bottom);
    const bool topmost_ok =
        ((ex_style & WS_EX_TOPMOST) != 0) == snapshot_.topmost;
    if (style == snapshot_.style && ex_style == snapshot_.ex_style && rect_ok &&
        topmost_ok) {
      restored = true;
    } else {
      *error = "回读校验失败：style=0x" +
               std::to_string(static_cast<long long>(style)) + "（期望 0x" +
               std::to_string(static_cast<long long>(snapshot_.style)) +
               "），ex_style=0x" +
               std::to_string(static_cast<long long>(ex_style)) + "（期望 0x" +
               std::to_string(static_cast<long long>(snapshot_.ex_style)) +
               "），rect=(" + std::to_string(rect.left) + "," +
               std::to_string(rect.top) + "," + std::to_string(rect.right) +
               "," + std::to_string(rect.bottom) + ")";
    }
  } else {
    *error = "恢复窗口 rect 失败（Win32 错误 " +
             std::to_string(::GetLastError()) + "）";
  }

  restoring_ = false;
  if (restored) {
    snapshot_.valid = false;
  }
  return restored;
}

bool CaptureWindowBridge::RepinOverlay(std::string* error, DWORD* win32_error) {
  *win32_error = ERROR_SUCCESS;
  if (window_ == nullptr || ::IsWindow(window_) == FALSE) {
    *error = "窗口句柄已经失效，无法重新钉回目标 rcMonitor";
    return false;
  }
  if (!snapshot_.valid) {
    *error = "没有 overlay 快照，无法重新钉回目标 rcMonitor";
    return false;
  }

  const int width = overlay_rect_.right - overlay_rect_.left;
  const int height = overlay_rect_.bottom - overlay_rect_.top;
  // 有限重试（最多 3 次、间隔 20ms）：重钉失败大多是瞬时的窗口状态变化，但绝不
  // 允许无限重试；每次失败都取真实的 Win32 错误码（§14.4 / 评审 2）。
  constexpr int kMaxAttempts = 3;
  constexpr DWORD kRetryDelayMs = 20;
  for (int attempt = 1; attempt <= kMaxAttempts; ++attempt) {
    ::SetLastError(ERROR_SUCCESS);
    if (::SetWindowPos(window_, HWND_TOPMOST, overlay_rect_.left,
                       overlay_rect_.top, width, height,
                       SWP_NOACTIVATE | SWP_NOOWNERZORDER |
                           SWP_FRAMECHANGED) != FALSE) {
      if (attempt > 1) {
        ::OutputDebugStringA(
            ("hax_shot: overlay repinned after " + std::to_string(attempt) +
             " attempts\n")
                .c_str());
      }
      return true;
    }
    *win32_error = ::GetLastError();
    if (attempt < kMaxAttempts) {
      ::Sleep(kRetryDelayMs);
    }
  }

  *error = "重新钉回目标 rcMonitor 失败：SetWindowPos 连续 " +
           std::to_string(kMaxAttempts) + " 次返回失败（Win32 错误 " +
           std::to_string(*win32_error) +
           "），浮层可能停在错误的屏幕或尺寸上";
  return false;
}

void CaptureWindowBridge::NotifyRepinFailure(const std::string& message,
                                             DWORD win32_error) {
  // 结构化失败证据的 native 半边：调试器输出 + 下面交给 Dart 的事件；
  // Dart 侧会把它写成 `overlay_repin_failed` 诊断日志。
  ::OutputDebugStringA(
      ("hax_shot: overlay repin failed: " + message + "\n").c_str());
  if (!channel_) {
    return;
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("win32Error")] =
      flutter::EncodableValue(static_cast<int64_t>(win32_error));
  payload[flutter::EncodableValue("message")] =
      flutter::EncodableValue(message);
  payload[flutter::EncodableValue("targetErrorCode")] =
      flutter::EncodableValue(static_cast<int64_t>(target_error_code_));
  payload[flutter::EncodableValue("overlayRect")] =
      flutter::EncodableValue(BuildOverlayRectPayload());
  channel_->InvokeMethod("overlayRepinFailed",
                         std::make_unique<flutter::EncodableValue>(payload));
}

flutter::EncodableMap CaptureWindowBridge::BuildOverlayRectPayload() const {
  flutter::EncodableMap rect;
  rect[flutter::EncodableValue("left")] =
      flutter::EncodableValue(static_cast<int64_t>(overlay_rect_.left));
  rect[flutter::EncodableValue("top")] =
      flutter::EncodableValue(static_cast<int64_t>(overlay_rect_.top));
  rect[flutter::EncodableValue("right")] =
      flutter::EncodableValue(static_cast<int64_t>(overlay_rect_.right));
  rect[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(static_cast<int64_t>(overlay_rect_.bottom));
  return rect;
}

flutter::EncodableMap CaptureWindowBridge::BuildStatePayload() const {
  RECT client_rect = {0, 0, 0, 0};
  if (window_ != nullptr && ::IsWindow(window_) != FALSE) {
    ::GetClientRect(window_, &client_rect);
  }
  flutter::EncodableMap rect;
  rect[flutter::EncodableValue("left")] =
      flutter::EncodableValue(static_cast<int64_t>(client_rect.left));
  rect[flutter::EncodableValue("top")] =
      flutter::EncodableValue(static_cast<int64_t>(client_rect.top));
  rect[flutter::EncodableValue("right")] =
      flutter::EncodableValue(static_cast<int64_t>(client_rect.right));
  rect[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(static_cast<int64_t>(client_rect.bottom));

  UINT dpi = 0;
  if (window_ != nullptr && ::IsWindow(window_) != FALSE) {
    dpi = ::FlutterDesktopGetDpiForHWND(window_);
  }
  if (dpi == 0) {
    dpi = target_.dpi;
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("displayId")] =
      flutter::EncodableValue(static_cast<int64_t>(target_.display_id));
  payload[flutter::EncodableValue("generation")] =
      flutter::EncodableValue(static_cast<int64_t>(target_.generation));
  payload[flutter::EncodableValue("clientRect")] =
      flutter::EncodableValue(rect);
  payload[flutter::EncodableValue("dpi")] =
      flutter::EncodableValue(static_cast<int64_t>(dpi));
  return payload;
}
