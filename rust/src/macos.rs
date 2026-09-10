//! macOS 平台后端：CoreGraphics 抓屏、NSPasteboard 写剪贴板、Carbon 全局快捷键。
//!
//! 平台差异只允许留在本模块，Flutter 侧看不到 CoreGraphics / Carbon / AppKit。

use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use core_foundation::url::CFURL;
use core_foundation_sys::base::{CFRelease, CFTypeRef};
use core_foundation_sys::string::CFStringRef;
use core_foundation_sys::url::CFURLRef;
use core_graphics::display::CGDisplay;
use core_graphics::event::CGEvent;
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;
use core_graphics::image::CGImage;
use core_graphics::sys::CGImageRef;
use foreign_types::ForeignType;
use objc2_app_kit::{NSPasteboard, NSPasteboardTypePNG};
use objc2_foundation::NSData;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::ptr;

use crate::unique_temp_path;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    /// 只查询 TCC 状态，不弹窗。
    fn CGPreflightScreenCaptureAccess() -> bool;
    /// 首次调用会弹出“屏幕录制”授权对话框；用户确认前返回 false。
    fn CGRequestScreenCaptureAccess() -> bool;
    /// 返回包含指定点的显示器列表；这里只关心第一个。
    fn CGGetDisplaysWithPoint(
        point: CGPoint,
        max_displays: u32,
        displays: *mut u32,
        matching_display_count: *mut u32,
    ) -> i32;
}

#[link(name = "ImageIO", kind = "framework")]
extern "C" {
    fn CGImageDestinationCreateWithURL(
        url: CFURLRef,
        image_type: CFStringRef,
        count: usize,
        options: *const c_void,
    ) -> *mut c_void;
    fn CGImageDestinationAddImage(
        destination: *mut c_void,
        image: CGImageRef,
        properties: *const c_void,
    );
    fn CGImageDestinationFinalize(destination: *mut c_void) -> bool;
}

/// 权限缺失时 hax_shot_capture_screen 返回的错误码，Dart 侧据此弹授权引导。
pub(crate) const SCREEN_CAPTURE_DENIED: i32 = -3;

/// 屏幕录制授权状态：1 已授权，0 未授权。
pub(crate) fn screen_capture_authorized_impl() -> u32 {
    // SAFETY: 只查询 TCC 状态，没有指针参数。
    u32::from(unsafe { CGPreflightScreenCaptureAccess() })
}

/// 请求屏幕录制授权：弹一次系统对话框，并把本 app 注册进“屏幕录制”列表。
pub(crate) fn request_screen_capture_access_impl() -> u32 {
    // SAFETY: 只请求 TCC 状态，没有指针参数。
    u32::from(unsafe { CGRequestScreenCaptureAccess() })
}

pub(crate) fn capture_screen_impl() -> Result<PathBuf, (i32, String)> {
    capture_screen_inner().map_err(|error| match error {
        CaptureError::Denied(message) => (SCREEN_CAPTURE_DENIED, message),
        CaptureError::Failed(message) => (-1, message),
    })
}

enum CaptureError {
    /// 没拿到屏幕录制授权（需要引导用户去系统设置）。
    Denied(String),
    Failed(String),
}

fn capture_screen_inner() -> Result<PathBuf, CaptureError> {
    ensure_screen_capture_access()?;

    let display = target_display();
    let image = display
        .image()
        .ok_or_else(|| CaptureError::Failed("CoreGraphics 没有返回显示器画面".to_owned()))?;

    // CGDisplayCreateImage 返回的是物理像素，Retina 屏上是逻辑尺寸的 2 倍。
    // Flutter 侧的浮层铺满同一块显示器的逻辑尺寸，正好 1:1 显示，
    // 裁剪和标注仍然按物理像素计算。
    if image.width() == 0 || image.height() == 0 {
        return Err(CaptureError::Failed("显示器画面尺寸为 0".to_owned()));
    }

    let destination = unique_temp_path();
    write_png(&image, &destination).map_err(CaptureError::Failed)?;
    Ok(destination)
}

/// 托盘宿主在触发截图时写入的目标显示器参数。
const DISPLAY_ARGUMENT: &str = "--display";

/// 本次截图要抓的显示器。
///
/// 顺序与 Runner 的 `CaptureDisplay.targetScreen()` 保持一致：
/// `--display <id>` → 光标所在显示器 → 主显示器。两边一旦不一致，就会出现
/// “浮层在 A 屏、画面是 B 屏”。
fn target_display() -> CGDisplay {
    for candidate in [requested_display_id(), cursor_display_impl()] {
        if candidate != 0 && is_active_display(candidate) {
            return CGDisplay::new(candidate);
        }
    }
    CGDisplay::main()
}

/// 读取托盘宿主通过命令行传进来的显示器标识；没传或不是合法数字时返回 0。
fn requested_display_id() -> u32 {
    display_id_from_arguments(std::env::args().skip(1))
}

fn display_id_from_arguments<I: Iterator<Item = String>>(mut arguments: I) -> u32 {
    while let Some(argument) = arguments.next() {
        if argument == DISPLAY_ARGUMENT {
            return arguments
                .next()
                .and_then(|value| value.parse().ok())
                .unwrap_or(0);
        }
    }
    0
}

fn is_active_display(id: u32) -> bool {
    CGDisplay::active_displays().is_ok_and(|displays| displays.contains(&id))
}

/// 光标所在显示器；拿不到光标位置时返回 0。
///
/// 两个分支都不能用 `unwrap`：截图进程不能因为拿不到光标就失败。
pub(crate) fn cursor_display_impl() -> u32 {
    let Ok(source) = CGEventSource::new(CGEventSourceStateID::CombinedSessionState) else {
        return 0;
    };
    let Ok(event) = CGEvent::new(source) else {
        return 0;
    };

    let mut displays = [0u32; 8];
    let mut count = 0u32;
    // SAFETY: displays 是长度 8 的数组，max_displays 与之一致，count 指向可写栈变量。
    let error = unsafe {
        CGGetDisplaysWithPoint(
            event.location(),
            displays.len() as u32,
            displays.as_mut_ptr(),
            &mut count,
        )
    };
    if error != 0 || count == 0 {
        return 0;
    }
    displays[0]
}

/// 交给 ImageIO 把 CGImage 直接编码成 PNG，不在 Rust 里重排像素。
fn write_png(image: &CGImage, path: &Path) -> Result<(), String> {
    let url = CFURL::from_path(path, false)
        .ok_or_else(|| format!("无法创建截图文件地址：{}", path.display()))?;
    let png_type = CFString::from_static_string("public.png");

    // SAFETY: url/png_type 在调用期间存活；destination 由本函数释放。
    unsafe {
        let destination = CGImageDestinationCreateWithURL(
            url.as_concrete_TypeRef(),
            png_type.as_concrete_TypeRef(),
            1,
            ptr::null(),
        );
        if destination.is_null() {
            return Err("无法创建 PNG 输出".to_owned());
        }

        CGImageDestinationAddImage(destination, image.as_ptr(), ptr::null());
        let finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination as CFTypeRef);

        if !finalized {
            let _ = std::fs::remove_file(path);
            return Err(format!("写入截图 PNG 失败：{}", path.display()));
        }
    }
    Ok(())
}

fn ensure_screen_capture_access() -> Result<(), CaptureError> {
    // SAFETY: 这两个函数只读取/请求 TCC 状态，没有指针参数。
    if unsafe { CGPreflightScreenCaptureAccess() } {
        return Ok(());
    }

    // 触发系统的授权对话框。用户在对话框里点“允许”时这里会返回 true，
    // 可以继续抓屏；还没点之前返回 false，第一次截图会带着下面的提示失败，
    // 授权后重试即可（这一步不能忽略返回值，否则授权成功的第一次仍然报错）。
    if unsafe { CGRequestScreenCaptureAccess() } {
        return Ok(());
    }

    Err(CaptureError::Denied(
        "macOS 未授予屏幕录制权限。请打开“系统设置 → 隐私与安全性 → 屏幕录制”，\
         勾选 Hax Shot 后重新截图。"
            .to_owned(),
    ))
}

pub(crate) fn copy_png_impl(data: &[u8]) -> Result<(), String> {
    if data.is_empty() {
        return Err("PNG data is empty".to_owned());
    }

    // NSPasteboard 属于 AppKit，只能在主线程调用。
    let pasteboard = NSPasteboard::generalPasteboard();
    let ns_data = NSData::with_bytes(data);
    pasteboard.clearContents();
    // SAFETY: NSPasteboardTypePNG 是 AppKit 提供的常量，数据类型与 NSData 匹配。
    let png_type = unsafe { NSPasteboardTypePNG };
    if !pasteboard.setData_forType(Some(&ns_data), png_type) {
        return Err("写入 macOS 剪贴板失败".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn reads_requested_display_from_arguments() {
        let parse = |values: &[&str]| display_id_from_arguments(arguments(values).into_iter());

        assert_eq!(parse(&["--capture", "--display", "3"]), 3);
        assert_eq!(parse(&["--display", "1", "--capture"]), 1);
        // 没有指定、值缺失或不是数字时都退回“没有目标显示器”。
        assert_eq!(parse(&["--capture"]), 0);
        assert_eq!(parse(&["--capture", "--display"]), 0);
        assert_eq!(parse(&["--display", "main"]), 0);
    }
}
