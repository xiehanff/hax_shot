//! Hax Shot 原生层：Flutter 通过 `dart:ffi` 只看到下面这几个 C ABI 函数。
//!
//! 平台实现分别放在 `linux` 和 `macos` 模块里，Flutter 侧看不到
//! Mutter / PipeWire / CoreGraphics / Carbon 这些平台细节。

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

use std::cmp::min;
use std::path::PathBuf;
use std::ptr;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static LAST_ERROR: OnceLock<Mutex<String>> = OnceLock::new();

fn last_error() -> &'static Mutex<String> {
    LAST_ERROR.get_or_init(|| Mutex::new(String::new()))
}

fn set_last_error(message: impl Into<String>) {
    if let Ok(mut error) = last_error().lock() {
        *error = message.into();
    }
}

fn clear_last_error() {
    set_last_error("");
}

fn write_bytes_to_buffer(bytes: &[u8], buffer: *mut u8, capacity: usize) -> usize {
    if buffer.is_null() || capacity == 0 {
        return bytes.len() + 1;
    }

    let copy_len = min(bytes.len(), capacity.saturating_sub(1));
    // SAFETY: the caller owns `buffer` and declares its capacity. We only write
    // at most capacity bytes, including the trailing NUL.
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, copy_len);
        *buffer.add(copy_len) = 0;
    }
    bytes.len() + 1
}

fn unique_temp_path() -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();

    std::env::temp_dir().join(format!("hax-shot-{}-{}.png", std::process::id(), timestamp))
}

#[cfg(target_os = "linux")]
use linux::{
    capture_screen_impl, copy_png_impl, cursor_display_impl, request_screen_capture_access_impl,
    screen_capture_authorized_impl,
};
#[cfg(target_os = "macos")]
use macos::{
    capture_screen_impl, copy_png_impl, cursor_display_impl, request_screen_capture_access_impl,
    screen_capture_authorized_impl,
};

/// Return the native library version used by the Flutter smoke test.
#[no_mangle]
pub extern "C" fn hax_shot_native_version() -> u32 {
    4
}

/// Whether the app may capture the screen right now.
///
/// Returns 1 when capture is allowed, 0 when the platform has not granted the
/// permission yet (macOS screen recording). The Flutter layer uses this to show
/// a permission guide *before* trying to capture, instead of covering the
/// screen with a failed capture overlay.
#[no_mangle]
pub extern "C" fn hax_shot_screen_capture_authorized() -> u32 {
    screen_capture_authorized_impl()
}

/// Ask the platform to grant screen capture access.
///
/// macOS 首次调用会弹出系统对话框，并把 Hax Shot 加进“系统设置 → 隐私与安全性 →
/// 屏幕录制”列表；用户同意前返回 0。Linux 上没有这个授权，直接返回 1。
#[no_mangle]
pub extern "C" fn hax_shot_request_screen_capture_access() -> u32 {
    request_screen_capture_access_impl()
}

/// Return the platform identifier of the display the pointer is on.
///
/// The tray host reads this once per capture and passes it to the `--capture`
/// process, so the selection overlay and the native capture always agree on the
/// same display. Returns 0 when the platform cannot report it.
#[no_mangle]
pub extern "C" fn hax_shot_cursor_display() -> u32 {
    cursor_display_impl()
}

/// Capture one frame of the target display and write it to a temporary PNG.
///
/// The target display is `--display <id>` when the tray host passed one, then the
/// display under the pointer, then the main display (see `rust/src/macos.rs`).
/// This must stay consistent with the display the Runner puts the overlay on.
///
/// On success, writes a NUL-terminated temporary PNG path to `out_path` and
/// returns 0. On failure returns -1, when the output buffer is too small returns
/// -2, and when the screen recording permission is missing returns -3 (the
/// Flutter layer turns that into a permission guide instead of an overlay).
#[no_mangle]
pub extern "C" fn hax_shot_capture_screen(out_path: *mut u8, capacity: usize) -> i32 {
    clear_last_error();

    let result = std::panic::catch_unwind(capture_screen_impl);
    match result {
        Ok(Ok(path)) => {
            let path_string = path.to_string_lossy();
            let required = path_string.len() + 1;
            if out_path.is_null() || capacity < required {
                set_last_error(format!(
                    "capture path buffer is too small; required {required} bytes"
                ));
                return -2;
            }

            write_bytes_to_buffer(path_string.as_bytes(), out_path, capacity);
            0
        }
        Ok(Err(error)) => {
            let (code, message) = error;
            set_last_error(message);
            code
        }
        Err(_) => {
            set_last_error("native capture panicked".to_owned());
            -1
        }
    }
}

/// Copy PNG bytes to the system image clipboard.
#[no_mangle]
pub extern "C" fn hax_shot_copy_png_to_clipboard(data: *const u8, length: usize) -> i32 {
    clear_last_error();

    if data.is_null() || length == 0 {
        set_last_error("PNG data pointer is null or empty".to_owned());
        return -1;
    }

    // SAFETY: the caller promises that `data` points to `length` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = std::panic::catch_unwind(|| copy_png_impl(bytes));

    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            set_last_error(error);
            -1
        }
        Err(_) => {
            set_last_error("native clipboard operation panicked".to_owned());
            -1
        }
    }
}

/// Copy the last native error into a caller-owned NUL-terminated buffer.
/// Returns the number of bytes required, including the NUL terminator.
#[no_mangle]
pub extern "C" fn hax_shot_last_error(buffer: *mut u8, capacity: usize) -> usize {
    let message = last_error()
        .lock()
        .map(|error| error.clone())
        .unwrap_or_else(|_| "native error state is unavailable".to_owned());
    write_bytes_to_buffer(message.as_bytes(), buffer, capacity)
}
