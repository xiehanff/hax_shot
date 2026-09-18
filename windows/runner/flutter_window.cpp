#include "flutter_window.h"

#include <optional>

#include "capture_window_bridge.h"
#include "flutter/generated_plugin_registrant.h"
#include "windows_shortcut_bridge.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 冻结画面浮层（Windows）的窗口属性 owner。挂在这条消息链上，但只在 overlay
  // 态接管 WM_NCCALCSIZE / WM_DPICHANGED（见 capture_window_bridge.cpp）。
  capture_window_bridge_ = std::make_unique<CaptureWindowBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());

  // 全局快捷键（Windows）：用**主窗口**的 HWND 注册，所以 WM_HOTKEY 会送到这条
  // 消息链上；注册/注销共用主线程的消息循环（§21/§22）。
  shortcut_bridge_ = std::make_unique<WindowsShortcutBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());

  // HaxShot 是托盘应用：窗口的可见性完全由 Dart（window_manager）控制。
  // 这里不注册 SetNextFrameCallback(Show)，也不调 ForceRedraw() 去逼首帧：
  // 宿主启动时窗口必须一直隐藏，`--capture` 子进程更要在浮层准备好之前
  // 保持隐藏，否则用户会先看到一个 1280x720 的默认窗口闪一下。
  // 注意“不显示”不等于“不创建”：窗口仍在这里创建，Dart 之后要 show 它。

  return true;
}

void FlutterWindow::OnDestroy() {
  // 先摘掉浮层通道再销毁引擎：桥的 handler 捕获了 this，而且它读的 HWND 马上
  // 就要没了。快捷键桥同理，而且它的析构里会 `UnregisterHotKey`——趁 HWND 还有效
  // 先做，不要指望系统在窗口销毁时替你清（§22 销毁）。
  capture_window_bridge_.reset();
  shortcut_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 浮层桥必须在 Flutter / 插件之前：window_manager 的顶层消息代理处理
  // WM_NCCALCSIZE 时，hidden titlebar 分支会把客户区缩进 8 像素并提前 return，
  // 放到它后面这段代码永远轮不到。桥只拦自己拥有的消息，其余返回 nullopt 放行。
  if (capture_window_bridge_) {
    std::optional<LRESULT> bridge_result =
        capture_window_bridge_->HandleMessage(hwnd, message, wparam, lparam);
    if (bridge_result) {
      return *bridge_result;
    }
  }

  // 全局快捷键：只吃掉自己的 WM_HOTKEY（固定 id），其余（包括其它插件注册的
  // 热键消息）返回 nullopt 继续走原链路。
  if (shortcut_bridge_) {
    std::optional<LRESULT> shortcut_result =
        shortcut_bridge_->HandleMessage(hwnd, message, wparam, lparam);
    if (shortcut_result) {
      return *shortcut_result;
    }
  }

  LRESULT result = 0;
  bool handled = false;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> flutter_result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (flutter_result) {
      result = *flutter_result;
      handled = true;
    }
  }

  if (!handled) {
    switch (message) {
      case WM_FONTCHANGE:
        flutter_controller_->engine()->ReloadSystemFonts();
        break;
    }
    result = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  // WM_DPICHANGED：默认链路（插件更新 ratio + Win32Window 按 suggested rect
  // 重新 SetWindowPos）跑完之后，再由桥把窗口钉回冻结元数据的 rcMonitor。
  // 顺序反了的话 Flutter 拿不到新 DPI，选区会错（§14.4）。
  if (capture_window_bridge_) {
    capture_window_bridge_->HandleMessageAfterDefault(hwnd, message, wparam,
                                                      lparam);
  }
  return result;
}
