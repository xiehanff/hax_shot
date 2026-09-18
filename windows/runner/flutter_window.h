#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "capture_window_bridge.h"
#include "win32_window.h"
#include "windows_shortcut_bridge.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 冻结画面浮层（Windows）的窗口属性 owner；普通面板态下不碰窗口。
  std::unique_ptr<CaptureWindowBridge> capture_window_bridge_;

  // 全局快捷键（Windows）：注册 / 注销 / WM_HOTKEY 转发，业务逻辑全在 Dart。
  std::unique_ptr<WindowsShortcutBridge> shortcut_bridge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
