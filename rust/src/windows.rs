//! Windows 后端。
//!
//! Phase 1 只提供**能编译、能给出可读失败**的 placeholder：抓屏与剪贴板都返回明确的
//! “尚未实现”，两个目标元数据导出返回 `NOT_IMPLEMENTED (7)`。真正的 GDI 抓屏、
//! `EnumDisplayMonitors` / `GetMonitorInfoW` / FNV-1a 设备 id 与冻结语义在 Phase 2 落地，
//! 并且**只在这里实现一次**——C++ / Dart 不允许再写一份选屏或 hash。

use std::path::PathBuf;

use crate::set_last_error;

/// Windows 没有 macOS 的屏幕录制授权流程，抓屏始终被系统允许。
pub(crate) fn screen_capture_authorized_impl() -> u32 {
    1
}

/// Windows 不需要请求授权；返回“已授权”以避免宿主弹出不存在的权限引导。
pub(crate) fn request_screen_capture_access_impl() -> u32 {
    1
}

/// 0 表示“平台暂时报不出光标所在显示器”，调用方按“未指定”处理。
///
/// 不要在这里返回任何看起来像真实显示器 id 的值：Phase 2 之前 Windows 还没有
/// szDevice → FNV-1a 的映射，伪造一个 id 会让宿主把错误的 `--display` 传给抓屏进程。
pub(crate) fn cursor_display_impl() -> u32 {
    0
}

/// Phase 2 才会实现：GDI 抓一帧目标显示器并写成临时 PNG。
pub(crate) fn capture_screen_impl() -> Result<PathBuf, (i32, String)> {
    Err((
        -1,
        "Windows capture backend is not implemented yet".to_owned(),
    ))
}

/// Phase 5 才会实现：写系统图片剪贴板（需要有效的 owner HWND，见 §33）。
pub(crate) fn copy_png_impl(_data: &[u8]) -> Result<(), String> {
    Err("Windows clipboard backend is not implemented yet".to_owned())
}

/// Phase 2 才会实现：解析本次截图的目标显示器（requested → 光标 → 主屏）。
pub(crate) fn target_monitor_impl(_requested: u32, _out: *mut crate::HaxShotTargetMonitor) -> i32 {
    set_last_error("Windows target monitor metadata is not implemented yet".to_owned());
    7
}

/// Phase 2 才会实现：读取本进程最近一次成功抓屏冻结的目标元数据。
pub(crate) fn last_capture_target_impl(_out: *mut crate::HaxShotTargetMonitor) -> i32 {
    set_last_error("Windows capture target metadata is not implemented yet".to_owned());
    7
}
