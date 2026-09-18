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
  static const captureReady = 'capture_ready';
  static const captureFinished = 'capture_finished';

  // 目标显示器元数据（Windows，见 rust/src/windows.rs）。
  static const captureTargetResolved = 'capture_target_resolved';
  static const captureSuspectedBlank = 'capture_suspected_blank';

  static const welcomeInitFailed = 'welcome_init_failed';

  static const appResumed = 'app_resumed';
  static const macosWake = 'macos_wake';
  static const macosUnlock = 'macos_unlock';
  static const macosSessionActive = 'macos_session_active';
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

  static const trayInitFailed = 'TRAY_INIT_FAILED';
  static const windowInitFailed = 'WINDOW_INIT_FAILED';
  static const welcomeInitFailed = 'WELCOME_INIT_FAILED';
}

/// 日志级别。
abstract final class LogLevel {
  static const info = 'info';
  static const warning = 'warning';
  static const error = 'error';
}
