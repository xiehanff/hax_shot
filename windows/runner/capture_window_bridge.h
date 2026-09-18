#ifndef RUNNER_CAPTURE_WINDOW_BRIDGE_H_
#define RUNNER_CAPTURE_WINDOW_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

/// `#[repr(C)] HaxShotTargetMonitor`（rust/src/lib.rs，§8.4）。
///
/// 只读：内容全部来自 Rust 的冻结元数据。C++ 侧**不得**自己枚举显示器、算 display
/// id 或选 fallback（§8.1），也不得改这个结构体的字段顺序 / 对齐。
struct HaxShotTargetMonitor {
  uint32_t valid;
  uint32_t error_code;
  uint32_t display_id;
  uint32_t reserved;
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
  int32_t width;
  int32_t height;
  uint32_t dpi;
  uint64_t generation;
};
static_assert(sizeof(HaxShotTargetMonitor) == 56,
              "HaxShotTargetMonitor 的布局必须与 rust/src/lib.rs 一致");

/// 冻结画面浮层（Windows）的窗口属性 owner（§14.2）。
///
/// 只接管 overlay 态的 rect / style / exStyle / topmost 与 WM_NCCALCSIZE；
/// 普通面板（AI 面板 / 设置页）的尺寸、层级、可缩放仍归 window_manager（§14.6）。
/// 窗口的显示 / 隐藏只由 Dart 触发：`becomeOverlay` **只配置、不显示**（§14.3）。
class CaptureWindowBridge {
 public:
  CaptureWindowBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~CaptureWindowBridge();

  CaptureWindowBridge(const CaptureWindowBridge&) = delete;
  CaptureWindowBridge& operator=(const CaptureWindowBridge&) = delete;

  /// 插件 / Flutter 之前的钩子：只拦 bridge 自己拥有的消息（overlay 态的
  /// WM_NCCALCSIZE），其余一律返回 nullopt 放行（§14.2）。
  std::optional<LRESULT> HandleMessage(HWND window,
                                       UINT message,
                                       WPARAM wparam,
                                       LPARAM lparam) noexcept;

  /// 默认链路（Flutter / 插件 / Win32Window）跑完之后的收尾。
  ///
  /// WM_DPICHANGED 必须先让 Flutter 与插件拿到新 DPI，再把窗口重新落位到冻结元数据的
  /// rcMonitor；否则窗口会停在 OS 建议的中间 rect，选区和客户区都会错（§14.4）。
  void HandleMessageAfterDefault(HWND window,
                                 UINT message,
                                 WPARAM wparam,
                                 LPARAM lparam) noexcept;

 private:
  /// 进入 overlay 之前快照的普通窗口状态，退出时按它恢复（§14.3 / §14.5）。
  struct WindowSnapshot {
    LONG_PTR style = 0;
    LONG_PTR ex_style = 0;
    RECT rect = {0, 0, 0, 0};
    bool zoomed = false;
    bool topmost = false;
    bool valid = false;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void BecomeOverlay(
      uint32_t display_id,
      uint64_t generation,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ExitOverlay(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  /// 按冻结元数据把窗口切成 overlay：style → rect → topmost，并回读校验客户区。
  bool ApplyOverlayPlacement(std::string* error);
  /// 按快照恢复 style / exStyle / rect / topmost，并回读校验。
  bool RestoreSnapshot(std::string* error);
  /// 把窗口重新钉回 overlay_rect_（WM_DPICHANGED 之后调用）。
  ///
  /// 检查 `SetWindowPos` 返回值与 Win32 错误码，失败时有限重试（最多 3 次）；
  /// 仍失败则把带操作名的原因写进 `error`、把真实错误码写进 `win32_error` 并返回
  /// false。调用方负责把物理契约标成失效并通知 Dart（§14.4 / 评审 2）。
  bool RepinOverlay(std::string* error, DWORD* win32_error);
  /// 重钉失败时通过 `hax_shot/capture_window` 通道主动通知 Dart
  /// （`overlayRepinFailed`）：浮层可能停在错误屏幕上，不能静默。
  void NotifyRepinFailure(const std::string& message, DWORD win32_error);
  /// 目标 rcMonitor 的 map（形状与 §14.8 的 `clientRect` 一致）。
  flutter::EncodableMap BuildOverlayRectPayload() const;
  /// 组装 §14.8 的返回值：displayId / generation / clientRect / dpi。
  flutter::EncodableMap BuildStatePayload() const;

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  WindowSnapshot snapshot_;
  /// 当前 overlay 的冻结元数据（成功进入后才有意义）。
  HaxShotTargetMonitor target_ = {};
  /// 目标 rcMonitor（物理像素，允许为负）。
  RECT overlay_rect_ = {0, 0, 0, 0};

  /// overlay 态：bridge 拥有窗口属性，Dart 不能再走插件去改同一个 HWND。
  bool overlay_active_ = false;
  /// 正在恢复快照：恢复期间的 WM_NCCALCSIZE 交还普通链路（hidden titlebar 分支）。
  bool restoring_ = false;

  /// WM_DPICHANGED 时目标已经消失的错误态（§14.4 第 3 步）；只记录，不撕掉浮层。
  int32_t target_error_code_ = 0;
  std::string target_error_message_;

  /// overlay 的物理契约（窗口 rect / 客户区 / 原点都等于目标 rcMonitor）当前是否
  /// 成立。进入 overlay 时置位，DPI 重钉失败时清掉：此后 `becomeOverlay` 幂等分支
  /// 不允许再返回一个“看着成功”的摆位结果（§14.4 / 评审 2）。
  bool overlay_contract_valid_ = false;
  /// 最近一次 DPI 重钉失败的可读原因与 Win32 错误码（通知 Dart / 幂等分支用）。
  std::string repin_error_message_;
  DWORD repin_win32_error_ = 0;
};

#endif  // RUNNER_CAPTURE_WINDOW_BRIDGE_H_
