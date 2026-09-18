// 诊断日志里使用的稳定事件名与错误码。
//
// 事件名/错误码一旦发布就不要改（`message` 可以变）：排查线上问题时是直接
// `grep` 这些字符串来还原链路，改名等于把历史日志废掉。

/// 事件名。见 docs/development-guide.md「截图触发链诊断日志」。
abstract final class DiagnosticEvent {
  static const appStart = 'app_start';

  static const desktopInitStart = 'desktop_init_start';
  static const desktopInitComplete = 'desktop_init_complete';

  static const windowInitFailed = 'window_init_failed';
  static const windowReadyFailed = 'window_ready_failed';

  static const trayInitStart = 'tray_init_start';
  static const trayInitSuccess = 'tray_init_success';
  static const trayInitFailed = 'tray_init_failed';

  static const shortcutRegisterStart = 'shortcut_register_start';
  static const shortcutRegisterSuccess = 'shortcut_register_success';
  static const shortcutRegisterFailed = 'shortcut_register_failed';
  static const shortcutUnregister = 'shortcut_unregister';
  static const shortcutPreferenceReadFailed = 'shortcut_preference_read_failed';
  static const shortcutPreferenceWriteFailed =
      'shortcut_preference_write_failed';
  static const shortcutPreferenceMigrated = 'shortcut_preference_migrated';
  static const shortcutRestoreStart = 'shortcut_restore_start';
  static const shortcutRestoreSuccess = 'shortcut_restore_success';
  static const shortcutRestoreFailed = 'shortcut_restore_failed';
  static const shortcutReactivateStart = 'shortcut_reactivate_start';
  static const shortcutReactivateSuccess = 'shortcut_reactivate_success';
  static const shortcutReactivateFailed = 'shortcut_reactivate_failed';

  static const shortcutTrigger = 'shortcut_trigger';
  static const menuCaptureTrigger = 'menu_capture_trigger';
  static const settingsCaptureTrigger = 'settings_capture_trigger';

  static const captureRequestCreated = 'capture_request_created';
  static const captureSpawnStart = 'capture_process_spawn_start';
  static const captureSpawnSuccess = 'capture_process_spawn_success';
  static const captureSpawnFailed = 'capture_process_spawn_failed';
  static const captureLaunchRejected = 'capture_launch_rejected';
  static const captureLaunchTimeout = 'capture_launch_timeout';

  static const captureChildStarted = 'capture_child_started';
  static const captureLockAcquired = 'capture_lock_acquired';
  static const captureLockBusy = 'capture_lock_busy';
  static const captureStartupFailed = 'capture_startup_failed';

  /// 图像已解码、可以开始交互。**不代表**窗口已经摆好：那看 [overlayReady]。
  static const captureReady = 'capture_ready';

  /// 浮层真的就绪了：`becomeOverlay` 成功 + `showWindow()` + `focus()` 都完成。
  ///
  /// 宿主不能用 [captureReady] 推断“窗口已正确显示”（§15.3/§56.2）。
  static const overlayReady = 'overlay_ready';

  /// 进入浮层失败（带原生 code，例如 5 = TARGET_STALE）：不 fallback、不显示旧图、
  /// 不释放捕获锁（§15.2/§17）。
  static const overlayBecomeFailed = 'overlay_become_failed';

  /// 浮层已经显示后，原生在 `WM_DPICHANGED` 重钉失败：物理契约不再成立，
  /// 页面必须走失败面板（§14.4 / 评审 2）。
  static const overlayRepinFailed = 'overlay_repin_failed';

  /// 失败面板 / 引导页的窗口**显示**失败（错误码用 [DiagnosticErrorCode.windowRevealFailed]）：
  /// 窗口显示不出来就不能留下一个隐藏且持锁的捕获进程（评审 6）。
  ///复用已有的 [windowReadyFailed] 事件名，不再新增事件。
  static const captureFinished = 'capture_finished';

  // 目标显示器元数据（Windows，见 rust/src/windows.rs）。
  static const captureTargetResolved = 'capture_target_resolved';
  static const captureSuspectedBlank = 'capture_suspected_blank';

  static const welcomeInitFailed = 'welcome_init_failed';

  static const appResumed = 'app_resumed';
  static const macosWake = 'macos_wake';
  static const macosUnlock = 'macos_unlock';
  static const macosSessionActive = 'macos_session_active';

  // 开机自启动（Windows 走 HKCU Run，见 autostart_service.dart）。
  // 失败时必须能直接看到注册表 API 的 LSTATUS 与目标值。
  static const autostartWriteSuccess = 'autostart_write_success';
  static const autostartRemoveSuccess = 'autostart_remove_success';
  static const autostartReadFailed = 'autostart_read_failed';
  static const autostartWriteFailed = 'autostart_write_failed';

  /// Run 值存在但不指向当前 exe（ZIP 换目录之后）：按未启用处理，但要留证据。
  static const autostartStaleValue = 'autostart_stale_value';

  // 剪贴板写入（写的是截图，不是 AI 输入框的读取路径）。
  static const clipboardCopySuccess = 'clipboard_copy_success';
  static const clipboardCopyFailed = 'clipboard_copy_failed';
}

/// 稳定错误码：日志里 `error_code` 只能是这里的值，自由文本放 `message`。
abstract final class DiagnosticErrorCode {
  static const shortcutRegisterFailed = 'SHORTCUT_REGISTER_FAILED';
  static const shortcutUnregisterFailed = 'SHORTCUT_UNREGISTER_FAILED';
  static const shortcutReactivateFailed = 'SHORTCUT_REACTIVATE_FAILED';
  static const shortcutRestoreFailed = 'SHORTCUT_RESTORE_FAILED';
  static const shortcutPreferenceFailed = 'SHORTCUT_PREFERENCE_FAILED';

  static const captureProcessSpawnFailed = 'CAPTURE_PROCESS_SPAWN_FAILED';
  static const captureChildTimeout = 'CAPTURE_CHILD_TIMEOUT';
  static const captureLockBusy = 'CAPTURE_LOCK_BUSY';
  static const captureStartupFailed = 'CAPTURE_STARTUP_FAILED';
  static const capturePermissionDenied = 'CAPTURE_PERMISSION_DENIED';
  static const overlayBecomeFailed = 'OVERLAY_BECOME_FAILED';
  static const overlayRepinFailed = 'OVERLAY_REPIN_FAILED';
  static const windowRevealFailed = 'WINDOW_REVEAL_FAILED';

  static const trayInitFailed = 'TRAY_INIT_FAILED';
  static const windowInitFailed = 'WINDOW_INIT_FAILED';
  static const welcomeInitFailed = 'WELCOME_INIT_FAILED';
  static const autostartFailed = 'AUTOSTART_FAILED';
  static const clipboardCopyFailed = 'CLIPBOARD_COPY_FAILED';
}

/// 日志级别。
abstract final class LogLevel {
  static const info = 'info';
  static const warning = 'warning';
  static const error = 'error';
}
