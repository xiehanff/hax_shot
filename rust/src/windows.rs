//! Windows 后端：GDI 抓屏 + 显示器枚举 / 选屏 + 冻结的目标元数据。
//!
//! 三件事都**只在这里实现一次**，C++ / Dart 只消费：
//!
//! - `EnumDisplayMonitors` + `GetMonitorInfoW(MONITORINFOEXW)` 枚举显示器，
//!   `szDevice` → FNV-1a 32 位 display id（[`fnv1a_display_id`]）；
//! - 选屏规则 [`resolve_target_monitor`]：`--display` → 光标所在显示器 → 主显示器；
//! - GDI 抓一帧写成临时 PNG，成功后把实际用的那块屏冻结进 [`CAPTURE_STATE`]，
//!   浮层摆位只能读 `hax_shot_last_capture_target`（§8.5）；
//! - PNG → 系统图片剪贴板（CF_DIBV5 + CF_DIB，即时数据，owner 窗口活在专职线程上）。

use std::collections::HashMap;
use std::ffi::c_void;
use std::io::Cursor;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use windows::core::{w, BOOL};
use windows::Win32::Foundation::{GetLastError, HANDLE, HGLOBAL, HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject,
    EnumDisplayMonitors, GetDC, GetDIBits, GetMonitorInfoW, MonitorFromPoint, ReleaseDC,
    SelectObject, BITMAPINFO, BITMAPINFOHEADER, BITMAPV5HEADER, BI_BITFIELDS, BI_RGB, CAPTUREBLT,
    CIEXYZTRIPLE, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ, HMONITOR, MONITORINFOEXW,
    MONITOR_DEFAULTTONEAREST, SRCCOPY,
};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE, GMEM_ZEROINIT,
};
use windows::Win32::System::Ole::{CF_DIB, CF_DIBV5};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, DispatchMessageW, GetCursorPos, PeekMessageW,
    MONITORINFOF_PRIMARY, MSG, PM_REMOVE, WS_EX_TOOLWINDOW, WS_POPUP,
};

use crate::{clear_last_error, set_last_error, unique_temp_path, HaxShotTargetMonitor};

/// ABI 错误码，与 `HaxShotTargetMonitor.error_code` / `hax_shot_*` 返回值同一套（§8.4）。
const OK: i32 = 0;
/// requested / cursor / primary 都拿不到目标。
const NO_TARGET: i32 = 1;
/// `EnumDisplayMonitors` 失败。
const ENUM_FAILED: i32 = 2;
/// `GetMonitorInfoW` 失败。
const DEVICE_NAME_FAILED: i32 = 3;
/// 两块屏的 display id 相同（或 hash 落到保留值 0，无法寻址）。
const HASH_COLLISION: i32 = 4;
/// 冻结的目标已消失 / rect 变了。
const TARGET_STALE: i32 = 5;
/// `out` 指针为空。
const INVALID_ARGUMENT: i32 = 6;

/// 单屏物理尺寸上限（§9.3）：超过直接失败，不静默截断。
const MAX_DIMENSION: i32 = 32768;

/// 单帧像素总数上限（§9.3）：[`MAX_DIMENSION`] 只管单轴，两个轴都到上限时 32bpp
/// 像素缓冲区是 4 GiB；这里按总像素再封一次顶，任何 GDI 调用之前就拒绝。
/// 64M 像素（≈256 MiB @32bpp）远高于 8K（7680x4320 ≈ 33M 像素），不是正常显示器。
const MAX_FRAME_PIXELS: usize = 64 * 1024 * 1024;

/// 单帧字节上限（32bpp），与 [`MAX_FRAME_PIXELS`] 等价；按字节再显式检查一次，
/// 保证任何分配点（`vec![0u8; buffer_len]`）之前都已经验过总量。
const MAX_FRAME_BYTES: usize = MAX_FRAME_PIXELS * 4;

/// 没有 macOS 的屏幕录制授权流程，抓屏始终被系统允许。
pub(crate) fn screen_capture_authorized_impl() -> u32 {
    1
}

/// Windows 不需要请求授权；返回“已授权”以避免宿主弹出不存在的权限引导。
pub(crate) fn request_screen_capture_access_impl() -> u32 {
    1
}

/// 光标所在显示器的 id（FNV-1a(szDevice)）；拿不到时返回 0（= 未指定）。
///
/// 宿主在用户触发截图的那一刻调用一次，把结果作为 `--display` 传给抓屏进程；
/// 这里和抓屏路径共用同一份枚举与编码，不会出现两边算出不同 id。
pub(crate) fn cursor_display_impl() -> u32 {
    let Some(handle) = cursor_monitor_handle() else {
        return 0;
    };
    let Ok(monitors) = enumerate_monitors() else {
        return 0;
    };
    monitors
        .iter()
        .find(|monitor| monitor.hmonitor == handle)
        .map_or(0, |monitor| monitor.display_id)
}

/// 抓一帧目标显示器并写成临时 PNG；成功后冻结目标元数据。
///
/// 失败按 §9.7 的策略带着操作名与真实 native code 返回，绝不返回“看着像成功”的图。
pub(crate) fn capture_screen_impl() -> Result<PathBuf, (i32, String)> {
    let requested = requested_display_id();
    let (monitor, source) = resolve_target_monitor(requested)?;
    // rcMonitor 的宽高只算一次：选屏、metadata、冻结都用这一份 checked 结果（§9.3）。
    let (width, height) = monitor.size().ok_or_else(|| {
        (
            NO_TARGET,
            format!(
                "backend=gdi requested={requested} source={} display_id={} rect={} rcMonitor 的宽高无法用 i32 表达或不是正数",
                source.label(),
                monitor.display_id,
                monitor.rect_label()
            ),
        )
    })?;
    let size = frame_size(width, height).map_err(|(code, message)| {
        (
            code,
            format!(
                "backend=gdi requested={requested} source={} display_id={} rect={} {message}",
                source.label(),
                monitor.display_id,
                monitor.rect_label()
            ),
        )
    })?;

    let frame = capture_frame(&monitor, &size).map_err(|(code, message)| {
        (
            code,
            format!(
                "backend=gdi requested={requested} source={} display_id={} rect={} size={}x{} stride={} dpi={} {message}",
                source.label(),
                monitor.display_id,
                monitor.rect_label(),
                size.width,
                size.height,
                size.stride,
                monitor.dpi
            ),
        )
    })?;

    let path = unique_temp_path();
    write_png(&path, &frame.pixels, size.width, size.height).map_err(|error| {
        (
            -1,
            format!(
                "backend=gdi requested={requested} display_id={} rect={} {error}",
                monitor.display_id,
                monitor.rect_label()
            ),
        )
    })?;

    freeze_target(&monitor, &frame);
    Ok(path)
}

/// 把 PNG 写进系统图片剪贴板（§33）。
///
/// 成立条件（细节见 `docs/development-guide.md` 的 Windows 一节）：
///
/// - **必须有有效的 owner HWND**：`OpenClipboard(NULL)` 之后 `EmptyClipboard` 会把
///   owner 置成 NULL，随后的 `SetClipboardData` 必然失败。owner 窗口由本模块的专职
///   线程创建并持有（0×0、`WS_POPUP`、`WS_EX_TOOLWINDOW`、从不显示），活到进程结束；
/// - **即时数据**，不用 delayed rendering：内存交出后归系统所有，与本进程是否存活无关，
///   抓屏子进程复制完立刻硬退出也照样能粘（§33.3/§33.6）；
/// - 格式：CF_DIBV5（基线，带 alpha / 色彩空间字段）+ CF_DIB（GDI 消费者的兼容副本），
///   两者都是 top-down（负 `biHeight`），与抓屏、PNG 的行顺序一致。
pub(crate) fn copy_png_impl(data: &[u8]) -> Result<(), String> {
    if data.is_empty() {
        return Err("PNG data is empty".to_owned());
    }

    let image = decode_png(data)?;
    let payloads = build_dib_payloads(&image)?;

    let (reply, reply_rx) = mpsc::channel();
    clipboard_client()?
        .send(ClipboardRequest {
            dib_v5: payloads.dib_v5,
            dib: payloads.dib,
            reply,
        })
        .map_err(|_| "the Windows clipboard thread has already exited".to_owned())?;
    reply_rx
        .recv()
        .map_err(|_| "the Windows clipboard thread exited while writing the clipboard".to_owned())?
}

/// 只查询当前拓扑下本次截图会选中的显示器（requested → 光标 → 主屏），不抓屏。
pub(crate) fn target_monitor_impl(requested: u32, out: *mut HaxShotTargetMonitor) -> i32 {
    if out.is_null() {
        set_last_error("hax_shot_target_monitor: out 指针为空".to_owned());
        return INVALID_ARGUMENT;
    }

    match resolve_target_monitor(requested) {
        Ok((monitor, _source)) => {
            // 只查询，没有本次抓屏：generation 用当前进度（= 最近一次成功抓屏的代际号），
            // 诊断位保持 0。
            let Some(metadata) = monitor.metadata(current_generation(), 0) else {
                // rcMonitor 的宽高塞不进 i32 / 不是正数：这不是可用的抓屏目标，
                // 按 NO_TARGET 处理（与“拿不到显示器”同一语义），并留下可读原因。
                set_last_error(format!(
                    "hax_shot_target_monitor(requested={requested}) 失败：display_id={} 的 rcMonitor {} 无法用有效的 i32 宽高表达",
                    monitor.display_id,
                    monitor.rect_label()
                ));
                // SAFETY: out 非空；失败也写一份 valid=0 的元数据，调用方可以统一读结构体。
                unsafe {
                    std::ptr::write(out, invalid_metadata(NO_TARGET));
                }
                return NO_TARGET;
            };
            clear_last_error();
            // SAFETY: out 非空（上面已判断），调用方按 ABI 分配了完整结构体。
            unsafe {
                std::ptr::write(out, metadata);
            }
            OK
        }
        Err((code, message)) => {
            set_last_error(format!(
                "hax_shot_target_monitor(requested={requested}) 失败：{message}"
            ));
            // SAFETY: out 非空；失败也写一份 valid=0 的元数据，调用方可以统一读结构体。
            unsafe {
                std::ptr::write(out, invalid_metadata(code));
            }
            code
        }
    }
}

/// 读本进程最近一次成功抓屏冻结的目标元数据（浮层摆位必须用它，§8.5）。
///
/// 目标消失 / rect 变化时按 §8.9 返回 `TARGET_STALE`：本次截图取消，不拿旧图套新屏。
pub(crate) fn last_capture_target_impl(out: *mut HaxShotTargetMonitor) -> i32 {
    if out.is_null() {
        set_last_error("hax_shot_last_capture_target: out 指针为空".to_owned());
        return INVALID_ARGUMENT;
    }

    let Some(frozen) = lock_capture_state().target.clone() else {
        set_last_error("hax_shot_last_capture_target: 本进程还没有成功抓屏过".to_owned());
        // SAFETY: out 非空，调用方按 ABI 分配了完整结构体。
        unsafe {
            std::ptr::write(out, invalid_metadata(NO_TARGET));
        }
        return NO_TARGET;
    };

    // 只读比对“这块屏还在不在、rect 有没有变”：不重新解析 fallback，也不换目标。
    let current = match enumerate_monitors() {
        Ok(monitors) => monitors
            .into_iter()
            .find(|monitor| monitor.display_id == frozen.display_id),
        Err((code, message)) => {
            set_last_error(format!(
                "hax_shot_last_capture_target: 无法校验冻结的目标显示器：{message}"
            ));
            // SAFETY: out 非空。
            unsafe {
                std::ptr::write(out, invalid_metadata(code));
            }
            return code;
        }
    };

    let stale_reason = match &current {
        None => Some(format!(
            "display_id={}（{}）已经不在当前显示器拓扑里",
            frozen.display_id, frozen.device_name
        )),
        Some(monitor)
            if monitor.rect.left != frozen.left
                || monitor.rect.top != frozen.top
                || monitor.rect.right != frozen.right
                || monitor.rect.bottom != frozen.bottom =>
        {
            Some(format!(
                "display_id={} 的 rect 从 ({},{},{},{}) 变成 {}",
                frozen.display_id,
                frozen.left,
                frozen.top,
                frozen.right,
                frozen.bottom,
                monitor.rect_label()
            ))
        }
        Some(_) => None,
    };

    if let Some(reason) = stale_reason {
        set_last_error(format!("冻结的抓屏目标已过期：{reason}"));
        // SAFETY: out 非空。
        unsafe {
            std::ptr::write(out, invalid_metadata(TARGET_STALE));
        }
        return TARGET_STALE;
    }

    clear_last_error();
    // 冻结时已经过 frame_size 校验，这里的 checked 只是保证 ABI 数字与 rect 一致：
    // 塞不进 i32 时宁可报 TARGET_STALE，也不能给出 wrap 后的宽高（§9.3）。
    let (Some(width), Some(height)) = (
        checked_axis(frozen.right, frozen.left),
        checked_axis(frozen.bottom, frozen.top),
    ) else {
        set_last_error(format!(
            "冻结的抓屏目标 rect ({},{},{},{}) 的宽高无法用 i32 表达",
            frozen.left, frozen.top, frozen.right, frozen.bottom
        ));
        // SAFETY: out 非空。
        unsafe {
            std::ptr::write(out, invalid_metadata(TARGET_STALE));
        }
        return TARGET_STALE;
    };
    // SAFETY: out 非空。
    unsafe {
        std::ptr::write(
            out,
            HaxShotTargetMonitor {
                valid: 1,
                error_code: 0,
                display_id: frozen.display_id,
                reserved: frozen.reserved,
                left: frozen.left,
                top: frozen.top,
                right: frozen.right,
                bottom: frozen.bottom,
                width,
                height,
                dpi: frozen.dpi,
                generation: frozen.generation,
            },
        );
    }
    OK
}

// ---------------------------------------------------------------- 显示器枚举

/// 一次枚举里的显示器；只在同一次调用内使用（`hmonitor` 不跨调用保存）。
#[derive(Clone)]
struct MonitorEntry {
    /// `EnumDisplayMonitors` 给的句柄，只用来和 `MonitorFromPoint` 的结果比较。
    hmonitor: HMONITOR,
    /// `MONITORINFOEXW.szDevice`（形如 `\\.\DISPLAY1`），只用于日志/错误信息。
    device_name: String,
    /// `szDevice` 的 FNV-1a 32 位结果；0 是保留值，表示这块屏无法寻址。
    display_id: u32,
    /// rcMonitor，物理像素，允许为负。
    rect: RECT,
    /// `GetDpiForMonitor` 的有效 DPI；失败填 0。
    dpi: u32,
    primary: bool,
}

/// `right - left` / `bottom - top`：先用 `i64` 相减再 checked 转 `i32`（§9.3）。
///
/// `RECT` 的坐标是有符号 `LONG`，直接做 `i32` 相减在 debug 下会 panic、release 下
/// 会 wrap；选屏、metadata、冻结三处必须共用这一份结果，不能各算各的。
fn checked_axis(right: i32, left: i32) -> Option<i32> {
    i32::try_from(i64::from(right) - i64::from(left)).ok()
}

impl MonitorEntry {
    /// rcMonitor 的宽高；任一轴塞不进 `i32` 或不是正数就返回 None。
    fn size(&self) -> Option<(i32, i32)> {
        let width = checked_axis(self.rect.right, self.rect.left)?;
        let height = checked_axis(self.rect.bottom, self.rect.top)?;
        (width > 0 && height > 0).then_some((width, height))
    }

    fn rect_label(&self) -> String {
        format!(
            "({},{},{},{})",
            self.rect.left, self.rect.top, self.rect.right, self.rect.bottom
        )
    }

    /// ABI 元数据；rcMonitor 的宽高塞不进 `i32` 时返回 None，由调用方决定怎么报错。
    fn metadata(&self, generation: u64, reserved: u32) -> Option<HaxShotTargetMonitor> {
        let (width, height) = self.size()?;
        Some(HaxShotTargetMonitor {
            valid: 1,
            error_code: 0,
            display_id: self.display_id,
            reserved,
            left: self.rect.left,
            top: self.rect.top,
            right: self.rect.right,
            bottom: self.rect.bottom,
            width,
            height,
            dpi: self.dpi,
            generation,
        })
    }
}

/// 失败时写给调用方的元数据：`valid = 0`，其余字段清零。
fn invalid_metadata(error_code: i32) -> HaxShotTargetMonitor {
    HaxShotTargetMonitor {
        valid: 0,
        error_code: error_code as u32,
        display_id: 0,
        reserved: 0,
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        width: 0,
        height: 0,
        dpi: 0,
        generation: 0,
    }
}

/// `EnumDisplayMonitors` 回调的收集袋。
#[derive(Default)]
struct Enumeration {
    monitors: Vec<MonitorEntry>,
    /// 回调里 `GetMonitorInfoW` 失败时记下的真实 Win32 错误码。
    device_name_error: Option<u32>,
}

/// `EnumDisplayMonitors` 的回调：只收集，不在这里决定成功与否。
///
/// 永远返回 TRUE：把所有失败收集齐之后再由 [`enumerate_monitors`] 决定，
/// 免得“回调主动 false”和“API 自己失败”在返回值上混成一种。
unsafe extern "system" fn collect_monitors(
    hmonitor: HMONITOR,
    _hdc: HDC,
    _clip: *mut RECT,
    data: LPARAM,
) -> BOOL {
    // SAFETY: `data` 是 enumerate_monitors() 传进来的 `&mut Enumeration`；
    // EnumDisplayMonitors 是同步调用，回调不会活过那次调用。
    let enumeration = unsafe { &mut *(data.0 as *mut Enumeration) };

    let mut info = MONITORINFOEXW::default();
    // cbSize 必须写成 MONITORINFOEXW 的大小，否则系统不会填 szDevice。
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    // SAFETY: info 是可写栈变量，cbSize 已按契约填好；
    // 文档承诺 GetMonitorInfoW 失败时设置 last error。
    if !unsafe { GetMonitorInfoW(hmonitor, &mut info.monitorInfo) }.as_bool() {
        // SAFETY: 失败后立刻读，中间没有别的 Win32 调用。
        enumeration.device_name_error = Some(unsafe { GetLastError() }.0);
        return BOOL(1);
    }

    let device_name = wide_string(&info.szDevice);

    enumeration.monitors.push(MonitorEntry {
        hmonitor,
        device_name,
        display_id: fnv1a_display_id(&info.szDevice),
        rect: info.monitorInfo.rcMonitor,
        dpi: monitor_dpi(hmonitor),
        primary: info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
    });
    BOOL(1)
}

/// 枚举当前所有显示器；id 冲突 / `GetMonitorInfoW` 失败都在这里明确失败。
fn enumerate_monitors() -> Result<Vec<MonitorEntry>, (i32, String)> {
    let mut enumeration = Enumeration::default();
    let data = LPARAM(std::ptr::from_mut(&mut enumeration) as isize);
    // SAFETY: 回调指针有效（签名与 MONITORENUMPROC 一致），data 指向本次调用的栈变量，
    // EnumDisplayMonitors 同步返回，回调不会逃逸。
    let enumerated = unsafe { EnumDisplayMonitors(None, None, Some(collect_monitors), data) };

    if !enumerated.as_bool() {
        // 回调永远返回 TRUE，所以这里只能是 EnumDisplayMonitors 自己失败：
        // 文档承诺失败时设置 last error，读它。
        // SAFETY: 失败后立刻读，中间没有别的 Win32 调用。
        let code = unsafe { GetLastError() }.0;
        return Err((
            ENUM_FAILED,
            format!("EnumDisplayMonitors failed: Win32 error {code}"),
        ));
    }

    if let Some(code) = enumeration.device_name_error {
        // 枚举结果不完整，不能拿它做选屏；按 §9.7 记自有错误码 + 真实 Win32 错误。
        return Err((
            DEVICE_NAME_FAILED,
            format!("GetMonitorInfoW failed for one of the monitors: Win32 error {code}"),
        ));
    }

    if enumeration.monitors.is_empty() {
        return Err((
            NO_TARGET,
            "EnumDisplayMonitors reported no monitors".to_owned(),
        ));
    }

    // 两块屏 id 相同 → 明确失败，不允许“选第一个假装成功”（§8.3）。
    let mut seen: HashMap<u32, usize> = HashMap::with_capacity(enumeration.monitors.len());
    for (index, monitor) in enumeration.monitors.iter().enumerate() {
        if monitor.display_id == 0 {
            continue;
        }
        if let Some(first) = seen.insert(monitor.display_id, index) {
            return Err((
                HASH_COLLISION,
                format!(
                    "display id {} 同时属于 {} 和 {}：szDevice 哈希碰撞，无法按 id 选屏",
                    monitor.display_id,
                    enumeration.monitors[first].device_name,
                    monitor.device_name
                ),
            ));
        }
    }

    Ok(enumeration.monitors)
}

/// `szDevice` → FNV-1a 32 位 display id，全工程唯一一份实现。
///
/// 规则（改动会让 Dart / C++ / Rust 三方对不上，见 docs/development-guide.md）：
/// - 逐 UTF-16 code unit 取**低字节**（`\\.\DISPLAY1` 本身是 ASCII）；
/// - offset basis `0x811C9DC5`、prime `0x01000193`，每字节一次 xor + wrapping_mul；
/// - 遇到终止 NUL 停止（不含 NUL），不做大小写转换。
fn fnv1a_display_id(device_name: &[u16]) -> u32 {
    const OFFSET_BASIS: u32 = 0x811C_9DC5;
    const PRIME: u32 = 0x0100_0193;

    let mut hash = OFFSET_BASIS;
    for unit in device_name {
        if *unit == 0 {
            break;
        }
        hash ^= u32::from(*unit as u8);
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

/// NUL 结尾的 UTF-16 缓冲区 → String（错误信息用，不做 lossy 之外的加工）。
fn wide_string(units: &[u16]) -> String {
    let length = units
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(units.len());
    String::from_utf16_lossy(&units[..length])
}

/// 显示器有效 DPI；拿不到时返回 0（`HaxShotTargetMonitor.dpi` 的约定）。
fn monitor_dpi(hmonitor: HMONITOR) -> u32 {
    let mut x = 0u32;
    let mut y = 0u32;
    // SAFETY: 两个输出参数都是可写栈变量；失败时不会写它们。
    match unsafe { GetDpiForMonitor(hmonitor, MDT_EFFECTIVE_DPI, &mut x, &mut y) } {
        Ok(()) if x > 0 => x,
        _ => 0,
    }
}

// -------------------------------------------------------------------- 选屏

/// 目标显示器是怎么被选中的，只用于日志。
#[derive(Clone, Copy)]
enum TargetSource {
    Requested,
    Cursor,
    Primary,
}

impl TargetSource {
    fn label(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::Cursor => "cursor",
            Self::Primary => "primary",
        }
    }
}

/// 选屏规则，全工程唯一一份：`requested` 非 0 且仍存在 → 光标所在显示器 → 主显示器。
///
/// 与 macOS `resolve_target_display` 逐字一致；`requested` 无效是**正常分支**
/// （用户可能刚拔掉副屏），既不报错也不造一个假 id，只是退回下一候选。
fn resolve_target_monitor(requested: u32) -> Result<(MonitorEntry, TargetSource), (i32, String)> {
    let monitors = enumerate_monitors()?;
    // id 为 0 的屏无法寻址：留在列表里只是为了诊断，不参与选择。
    let addressable: Vec<&MonitorEntry> = monitors
        .iter()
        .filter(|monitor| monitor.display_id != 0)
        .collect();

    if requested != 0 {
        if let Some(monitor) = addressable
            .iter()
            .find(|monitor| monitor.display_id == requested)
        {
            return Ok(((*monitor).clone(), TargetSource::Requested));
        }
    }

    if let Some(handle) = cursor_monitor_handle() {
        if let Some(monitor) = addressable
            .iter()
            .find(|monitor| monitor.hmonitor == handle)
        {
            return Ok(((*monitor).clone(), TargetSource::Cursor));
        }
    }

    if let Some(monitor) = addressable.iter().find(|monitor| monitor.primary) {
        return Ok(((*monitor).clone(), TargetSource::Primary));
    }

    Err((
        NO_TARGET,
        format!(
            "no addressable target monitor (requested={requested}, {} monitor(s) enumerated){}",
            monitors.len(),
            unaddressable_notes(&monitors)
        ),
    ))
}

/// “无法寻址的显示器”诊断：`hash == 0` 的屏不参与选择，但要在诊断里说清楚。
fn unaddressable_notes(monitors: &[MonitorEntry]) -> String {
    let names: Vec<&str> = monitors
        .iter()
        .filter(|monitor| monitor.display_id == 0)
        .map(|monitor| monitor.device_name.as_str())
        .collect();
    if names.is_empty() {
        String::new()
    } else {
        format!(
            "; szDevice hashing to the reserved id 0 (not addressable): {}",
            names.join(", ")
        )
    }
}

/// 光标所在显示器的句柄；拿不到位置时返回 None（调用方按“未指定”处理，不报错）。
fn cursor_monitor_handle() -> Option<HMONITOR> {
    let mut point = POINT::default();
    // SAFETY: point 是可写栈变量。GetCursorPos 文档承诺失败时设置 last error，
    // 但“不知道鼠标在哪”是正常分支，不需要错误信息。
    if unsafe { GetCursorPos(&mut point) }.is_err() {
        return None;
    }
    // SAFETY: 任意点都能映射到最近的显示器；只有点不在任何显示器上时返回空句柄。
    let handle = unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) };
    (!handle.0.is_null()).then_some(handle)
}

/// 读取托盘宿主传进来的 `--display <id>`；缺失 / 非法一律当作 0（未指定）。
fn requested_display_id() -> u32 {
    crate::display_id_from_arguments(std::env::args().skip(1))
}

// --------------------------------------------------------------- GDI 抓屏

/// 已经校验过的抓屏尺寸（32bpp，stride = width * 4，天然 DWORD 对齐）。
struct FrameSize {
    width: i32,
    height: i32,
    stride: usize,
    buffer_len: usize,
}

/// 任何 Win32 调用之前先校验尺寸与溢出（§9.3）；不合法就失败，不静默截断。
fn frame_size(width: i32, height: i32) -> Result<FrameSize, (i32, String)> {
    if width <= 0 || height <= 0 {
        return Err((
            -1,
            format!("monitor size {width}x{height} is not a usable capture size"),
        ));
    }
    if width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err((
            -1,
            format!("monitor size {width}x{height} exceeds the {MAX_DIMENSION} pixel limit"),
        ));
    }

    let width_usize = usize::try_from(width)
        .map_err(|_| (-1, format!("width {width} does not fit into usize")))?;
    let height_usize = usize::try_from(height)
        .map_err(|_| (-1, format!("height {height} does not fit into usize")))?;
    // 总量上限必须在**任何** GDI 调用 / 分配之前检查（§9.3）：单轴上限挡不住
    // “32768x32768 → 4 GiB”这种极端组合。
    let pixel_count = width_usize
        .checked_mul(height_usize)
        .ok_or_else(|| (-1, format!("pixel count overflow for {width}x{height}")))?;
    if pixel_count > MAX_FRAME_PIXELS {
        return Err((
            -1,
            format!(
                "monitor size {width}x{height} needs {pixel_count} pixels, over the {MAX_FRAME_PIXELS} pixel frame limit"
            ),
        ));
    }
    let stride = width_usize
        .checked_mul(4)
        .ok_or_else(|| (-1, format!("stride overflow for width {width}")))?;
    let buffer_len = stride
        .checked_mul(height_usize)
        .ok_or_else(|| (-1, format!("buffer size overflow for {width}x{height}")))?;
    if buffer_len > MAX_FRAME_BYTES {
        return Err((
            -1,
            format!(
                "monitor size {width}x{height} needs {buffer_len} bytes, over the {MAX_FRAME_BYTES} byte frame limit"
            ),
        ));
    }

    Ok(FrameSize {
        width,
        height,
        stride,
        buffer_len,
    })
}

/// 一帧 RGBA8 像素 + 全黑诊断的采样结果。
struct CapturedFrame {
    pixels: Vec<u8>,
    suspected_blank: bool,
    mean_luma: u8,
}

/// `GetDC(NULL)` 的 RAII：任何退出路径都会 `ReleaseDC`。
struct ScreenDc(HDC);

impl ScreenDc {
    fn acquire() -> Result<Self, (i32, String)> {
        // SAFETY: GetDC(NULL) 取整个虚拟屏幕的 DC，没有前置条件；失败返回空句柄。
        let dc = unsafe { GetDC(None) };
        if dc.0.is_null() {
            // GetDC 的文档只承诺失败返回 NULL，**没有**承诺设置 last error，
            // 所以这里记操作名与自有错误码，不声称是系统错误（§9.7）。
            return Err((-1, "GetDC(NULL) returned a null device context".to_owned()));
        }
        Ok(Self(dc))
    }
}

impl Drop for ScreenDc {
    fn drop(&mut self) {
        // SAFETY: 句柄来自 GetDC(NULL)，只在这里释放一次；返回值只说明是否释放成功。
        unsafe { ReleaseDC(None, self.0) };
    }
}

/// `CreateCompatibleDC` 的 RAII。
struct MemoryDc(HDC);

impl MemoryDc {
    fn create(source: HDC) -> Result<Self, (i32, String)> {
        // SAFETY: source 是有效的 screen DC；失败返回空句柄。
        let dc = unsafe { CreateCompatibleDC(Some(source)) };
        if dc.0.is_null() {
            return Err((
                -1,
                "CreateCompatibleDC returned a null device context".to_owned(),
            ));
        }
        Ok(Self(dc))
    }
}

impl Drop for MemoryDc {
    fn drop(&mut self) {
        // SAFETY: 句柄由 CreateCompatibleDC 创建，只在这里删除一次。
        unsafe {
            let _ = DeleteDC(self.0);
        }
    }
}

/// 兼容位图 + “当前被选进哪个 DC”的状态。
///
/// Drop 顺序（位图 → memory DC → screen DC）保证失败路径也不漏资源：先按记录的旧
/// 对象选回（`GetDIBits` 要求位图不被任何 DC 选中），再 `DeleteObject`。
struct Bitmap {
    handle: HBITMAP,
    selected_in: Option<(HDC, HGDIOBJ)>,
}

impl Bitmap {
    fn create(source: HDC, size: &FrameSize) -> Result<Self, (i32, String)> {
        // 必须用**源 DC**（screen DC）创建：用刚建的 memory DC 会得到 1x1 单色位图。
        // SAFETY: source 有效；宽高已由 frame_size 校验为正且不超过上限。
        let bitmap = unsafe { CreateCompatibleBitmap(source, size.width, size.height) };
        if bitmap.0.is_null() {
            return Err((
                -1,
                format!(
                    "CreateCompatibleBitmap({}x{}) returned a null bitmap",
                    size.width, size.height
                ),
            ));
        }
        Ok(Self {
            handle: bitmap,
            selected_in: None,
        })
    }

    fn select_into(&mut self, dc: HDC) -> Result<(), (i32, String)> {
        // SAFETY: dc 与 handle 都有效；失败返回 NULL 或 HGDI_ERROR。
        let previous = unsafe { SelectObject(dc, self.handle.into()) };
        if previous.0.is_null() || previous.0 as isize == -1 {
            return Err((
                -1,
                "SelectObject failed to select the capture bitmap".to_owned(),
            ));
        }
        self.selected_in = Some((dc, previous));
        Ok(())
    }

    /// 把位图从 DC 里选回旧对象；`GetDIBits` 之前必须调用（§9.1 的硬约束）。
    ///
    /// 只有 `SelectObject` 成功才清掉 `selected_in`：失败时位图**仍在 DC 里选着**，
    /// 状态必须保留，让调用方中止 `GetDIBits`、让 Drop 还有机会重试（评审 3）。
    fn unselect(&mut self) -> Result<(), (i32, String)> {
        let Some((dc, previous)) = self.selected_in else {
            return Ok(());
        };
        // SAFETY: dc / previous 都是 SelectObject 之前的有效句柄。
        // 注意 `SelectObject` 没有「失败时设置 last error」的文档契约，所以只报操作名，
        // 不声称系统错误码（§9.7）。
        let replaced = unsafe { SelectObject(dc, previous) };
        if replaced.0.is_null() || replaced.0 as isize == -1 {
            return Err((
                -1,
                "SelectObject failed to restore the previous GDI object; the capture bitmap is still selected in the DC"
                    .to_owned(),
            ));
        }
        self.selected_in = None;
        Ok(())
    }
}

impl Drop for Bitmap {
    fn drop(&mut self) {
        match self.unselect() {
            Ok(()) => {
                // SAFETY: handle 由 CreateCompatibleBitmap 创建、已经从 DC 里选回，
                // 只删一次。
                unsafe {
                    let _ = DeleteObject(self.handle.into());
                }
            }
            Err(_) => {
                // 还没解除选择：`DeleteObject` 可能删掉 DC 正在使用的对象，导致 DC
                // 持有悬空句柄（GDI 泄漏 / 后续绘制失败）。这里宁可漏掉一个 GDI
                // 对象，也不把“没解除选择”当成已解除（评审 3）。
            }
        }
    }
}

/// 抓一帧：`GetDC(NULL)` → 兼容位图 → `BitBlt` → `GetDIBits` → BGRA→RGBA（A=255）。
fn capture_frame(monitor: &MonitorEntry, size: &FrameSize) -> Result<CapturedFrame, (i32, String)> {
    let screen_dc = ScreenDc::acquire()?;
    let memory_dc = MemoryDc::create(screen_dc.0)?;
    let mut bitmap = Bitmap::create(screen_dc.0, size)?;
    bitmap.select_into(memory_dc.0)?;

    // SRCCOPY|CAPTUREBLT：尽量把 layered window 也算进去，但**不是**对硬件 overlay /
    // 鼠标指针 / 色彩管理的承诺（§9.6）；本版不合成鼠标。
    let blitted = unsafe {
        BitBlt(
            memory_dc.0,
            0,
            0,
            size.width,
            size.height,
            Some(screen_dc.0),
            monitor.rect.left,
            monitor.rect.top,
            SRCCOPY | CAPTUREBLT,
        )
    };
    if let Err(error) = blitted {
        return Err((
            -1,
            format!(
                "BitBlt failed at ({},{},{},{}): Win32 error {}",
                monitor.rect.left,
                monitor.rect.top,
                size.width,
                size.height,
                win32_error_code(&error)
            ),
        ));
    }

    // ★ GetDIBits 要求位图不被任何 DC 选中：先选回旧对象。解除选择失败必须中止，
    // 不能带着“位图还选在 DC 里”的状态去 GetDIBits（评审 3）。Drop 里还会兜一次，
    // 但那时如果仍失败，就不会删这个位图。
    bitmap
        .unselect()
        .map_err(|(_code, message)| (-1, message))?;

    let mut info = BITMAPINFO::default();
    info.bmiHeader = BITMAPINFOHEADER {
        biSize: size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: size.width,
        // top-down：负高度，Flutter 侧不需要再翻转（§9.4）。
        biHeight: -size.height,
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB.0,
        ..Default::default()
    };

    let mut raw = vec![0u8; size.buffer_len];
    // SAFETY: raw 至少有 stride * height 字节；位图已经选回；info 已按 GetDIBits 契约填好。
    // height 已校验为正数，转 u32 不会丢信息。
    let lines = unsafe {
        GetDIBits(
            screen_dc.0,
            bitmap.handle,
            0,
            size.height as u32,
            Some(raw.as_mut_ptr().cast::<c_void>()),
            &mut info,
            DIB_RGB_COLORS,
        )
    };
    if lines != size.height {
        // GetDIBits 的返回值只能说明“拷了多少行”，不是系统错误码，所以不声称是错误码。
        return Err((
            -1,
            format!(
                "GetDIBits copied {lines} scan lines, expected {} (bitmap {}x{})",
                size.height, size.width, size.height
            ),
        ));
    }

    // 确认系统没有默默改掉我们自己填的字段；不一致就失败，不按“大概能看”凑合（§9.5）。
    let header = &info.bmiHeader;
    if header.biSize != size_of::<BITMAPINFOHEADER>() as u32
        || header.biWidth != size.width
        || header.biHeight != -size.height
        || header.biBitCount != 32
        || header.biCompression != BI_RGB.0
    {
        return Err((
            -1,
            format!(
                "GetDIBits rewrote BITMAPINFOHEADER to {}x{} {}bpp compression {} (expected top-down {}x{} 32bpp BI_RGB)",
                header.biWidth,
                header.biHeight,
                header.biBitCount,
                header.biCompression,
                size.width,
                size.height
            ),
        ));
    }

    // DIB 是 BGRA（普通 GDI 截图里 alpha 不可靠）：转成 RGBA，alpha 统一写 255，
    // 绝不把未初始化的 alpha 写进 PNG（§9.4）。
    let mut pixels = vec![0u8; size.buffer_len];
    for (source, destination) in raw.chunks_exact(4).zip(pixels.chunks_exact_mut(4)) {
        destination[0] = source[2];
        destination[1] = source[1];
        destination[2] = source[0];
        destination[3] = 255;
    }

    let sample = sample_luma(&pixels);
    Ok(CapturedFrame {
        pixels,
        suspected_blank: sample.suspected_blank,
        mean_luma: sample.mean_luma,
    })
}

/// `windows_core::Error` 里的真实 Win32 错误码（`BitBlt` 这类 API 通过它回传）。
fn win32_error_code(error: &windows::core::Error) -> u32 {
    let code = error.code().0 as u32;
    // HRESULT_FROM_WIN32: 0x8007xxxx，低 16 位才是原始 Win32 错误码。
    if code & 0xFFFF_0000 == 0x8007_0000 {
        code & 0xFFFF
    } else {
        code
    }
}

/// 全黑诊断的一次采样结果。
struct LumaSample {
    mean_luma: u8,
    suspected_blank: bool,
}

/// 步长采样平均亮度，只用来给日志一个 `suspected_blank` 告警（§9.8）。
///
/// 黑桌面 / 全黑壁纸都是合法画面，**不允许**据此把截图判为失败或自动重截。
fn sample_luma(pixels: &[u8]) -> LumaSample {
    /// 采样上限：一张 4K 截图最多看这么多像素，开销可忽略。
    const MAX_SAMPLES: usize = 4096;

    let pixel_count = pixels.len() / 4;
    if pixel_count == 0 {
        return LumaSample {
            mean_luma: 0,
            suspected_blank: false,
        };
    }

    let step = (pixel_count / MAX_SAMPLES).max(1);
    let mut total: u64 = 0;
    let mut samples: u64 = 0;
    let mut brightest: u8 = 0;
    for index in (0..pixel_count).step_by(step) {
        let offset = index * 4;
        let luma = (299 * u32::from(pixels[offset])
            + 587 * u32::from(pixels[offset + 1])
            + 114 * u32::from(pixels[offset + 2]))
            / 1000;
        let luma = luma as u8;
        total += u64::from(luma);
        samples += 1;
        brightest = brightest.max(luma);
    }

    let mean_luma = (total / samples.max(1)) as u8;
    // 只有“整体接近纯黑且几乎没有亮点”才算疑似：抓受保护内容 / 显卡 overlay 失败时
    // 是这种形态，而深色桌面往往还留着任务栏或窗口的亮部。
    LumaSample {
        mean_luma,
        suspected_blank: mean_luma <= 2 && brightest <= 16,
    }
}

/// 用 `png` crate 把 RGBA8 写进临时文件；失败删掉半成品，不留 0 字节或半截 PNG（§9.9）。
fn write_png(path: &Path, pixels: &[u8], width: i32, height: i32) -> Result<(), String> {
    let result = write_png_inner(path, pixels, width, height);
    if result.is_err() {
        // 删除失败不能掩盖主错误：这里刻意忽略删除本身的错误。
        let _ = std::fs::remove_file(path);
    }
    result
}

fn write_png_inner(path: &Path, pixels: &[u8], width: i32, height: i32) -> Result<(), String> {
    let file = std::fs::File::create(path)
        .map_err(|error| format!("failed to create {}: {error}", path.display()))?;
    let mut encoder = png::Encoder::new(file, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    // 与 lib.rs 的 encode_png 一致：Fast（fdeflate）在截图这种低频动作上最划算。
    encoder.set_compression(png::Compression::Fast);

    let mut writer = encoder
        .write_header()
        .map_err(|error| format!("failed to write PNG header to {}: {error}", path.display()))?;
    writer
        .write_image_data(pixels)
        .map_err(|error| format!("failed to write PNG data to {}: {error}", path.display()))?;
    writer
        .finish()
        .map_err(|error| format!("failed to finish PNG at {}: {error}", path.display()))?;
    Ok(())
}

// --------------------------------------------------------- 冻结的目标元数据

/// `reserved` 的位域：bit 0 = 疑似全黑，bit 8..=15 = 采样平均亮度（0..255）。
const SUSPECTED_BLANK_FLAG: u32 = 1 << 0;
const MEAN_LUMA_SHIFT: u32 = 8;

/// 抓屏成功那一刻冻结的目标显示器（§8.5：一次解析、两处消费）。
#[derive(Clone)]
struct FrozenTarget {
    display_id: u32,
    device_name: String,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    dpi: u32,
    generation: u64,
    reserved: u32,
}

/// 抓屏代际号 + 最近一次成功抓屏的目标。
///
/// 抓屏跑在 worker isolate 的线程上，读元数据（日志、Phase 3 的浮层摆位）在别的
/// 线程，所以必须是 `Mutex`：不能用 `Cell` / `Rc` 这类单线程容器（§8.6）。
struct CaptureState {
    generation: u64,
    target: Option<FrozenTarget>,
}

static CAPTURE_STATE: OnceLock<Mutex<CaptureState>> = OnceLock::new();

fn lock_capture_state() -> MutexGuard<'static, CaptureState> {
    let state = CAPTURE_STATE.get_or_init(|| {
        Mutex::new(CaptureState {
            generation: 0,
            target: None,
        })
    });
    match state.lock() {
        Ok(guard) => guard,
        // 抓屏线程 panic 会毒化 Mutex；元数据本身仍然可用，不能因此让整个进程读不到目标。
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// 当前抓屏代际号（最近一次成功抓屏的号；还没成功过就是 0）。
fn current_generation() -> u64 {
    lock_capture_state().generation
}

/// 冻结本次成功抓屏的目标；`generation` 每成功一次 +1（溢出不处理，实际不可能）。
fn freeze_target(monitor: &MonitorEntry, frame: &CapturedFrame) -> u64 {
    let mut state = lock_capture_state();
    state.generation = state.generation.wrapping_add(1);
    state.target = Some(FrozenTarget {
        display_id: monitor.display_id,
        device_name: monitor.device_name.clone(),
        left: monitor.rect.left,
        top: monitor.rect.top,
        right: monitor.rect.right,
        bottom: monitor.rect.bottom,
        dpi: monitor.dpi,
        generation: state.generation,
        reserved: capture_flags(frame),
    });
    state.generation
}

/// `reserved` 的诊断位：疑似全黑 + 采样平均亮度。
fn capture_flags(frame: &CapturedFrame) -> u32 {
    let blank = if frame.suspected_blank {
        SUSPECTED_BLANK_FLAG
    } else {
        0
    };
    blank | (u32::from(frame.mean_luma) << MEAN_LUMA_SHIFT)
}

// --------------------------------------------------------------------- 剪贴板

/// `OpenClipboard` 的重试次数与间隔（§33.5）：剪贴板可能被别的进程短短地占住，
/// 但绝不允许无限循环。
const OPEN_ATTEMPTS: u32 = 5;
const OPEN_RETRY_DELAY: Duration = Duration::from_millis(20);

/// `BITMAPV5HEADER.bV5CSType`：`LCS_sRGB`（wingdi.h 里的 'sRGB' 四字符码）。
///
/// 用了它，系统就忽略 gamma / endpoints 字段，截图的 sRGB 像素不需要额外的色彩管理。
const LCS_SRGB: u32 = 0x7352_4742;

/// 一次剪贴板写入请求：两种 DIB 都已准备好，交给专职线程写进系统剪贴板。
struct ClipboardRequest {
    /// CF_DIBV5 的完整体（BITMAPV5HEADER + 像素）。
    dib_v5: Vec<u8>,
    /// CF_DIB 的完整体（BITMAPINFOHEADER + 像素）。
    dib: Vec<u8>,
    /// worker 写完之后回一个结果；调用方阻塞等它。
    reply: Sender<Result<(), String>>,
}

/// 专职剪贴板线程的请求通道。
///
/// 存的是“建线程的结果”：owner 窗口创建失败时把错误缓存下来，不每次重新建线程。
static CLIPBOARD_CLIENT: OnceLock<Mutex<Option<Result<Sender<ClipboardRequest>, String>>>> =
    OnceLock::new();

/// 拿专职剪贴板线程的发送端；第一次调用时把线程和它的 owner 窗口建起来。
fn clipboard_client() -> Result<Sender<ClipboardRequest>, String> {
    let slot = CLIPBOARD_CLIENT.get_or_init(|| Mutex::new(None));
    let mut cached = match slot.lock() {
        Ok(guard) => guard,
        // 上个调用方 panic 会毒化 Mutex；缓存本身仍然可用，不能让它把剪贴板全废掉。
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some(existing) = cached.as_ref() {
        return existing.clone();
    }
    let started = start_clipboard_thread();
    *cached = Some(started.clone());
    started
}

/// 起专职线程：创建 owner 窗口 → 报告就绪 → 串行处理写入请求。
///
/// 线程必须活着：`WS_POPUP` 的 owner 窗口由它创建，创建者线程一结束窗口就没了，
/// 而剪贴板 owner 窗口要活到进程结束（§33.2）。这里用 `recv_timeout` + 消息泵，
/// 既不忙等，也保证窗口所在线程一直在处理消息。
fn start_clipboard_thread() -> Result<Sender<ClipboardRequest>, String> {
    let (ready_tx, ready_rx) = mpsc::channel::<Result<Sender<ClipboardRequest>, String>>();
    let (request_tx, request_rx) = mpsc::channel::<ClipboardRequest>();
    let worker_request_tx = request_tx.clone();

    thread::Builder::new()
        .name("hax-shot-clipboard".to_owned())
        .spawn(move || {
            let owner = match create_owner_window() {
                Ok(owner) => owner,
                Err(error) => {
                    let _ = ready_tx.send(Err(error));
                    return;
                }
            };
            // 先把发送端交回调用方，再进入请求循环。
            if ready_tx.send(Ok(worker_request_tx)).is_err() {
                // 调用方已经走了（例如进程正在退出）：窗口没人用，直接收掉。
                // SAFETY: owner 是本线程刚创建的窗口，只销毁一次。
                unsafe {
                    let _ = DestroyWindow(owner);
                }
                return;
            }

            loop {
                pump_thread_messages();
                match request_rx.recv_timeout(OPEN_RETRY_DELAY) {
                    Ok(request) => {
                        let result = write_clipboard(owner, &request);
                        // 回包失败说明调用方已经不等了（进程退出中），继续处理下一个请求。
                        let _ = request.reply.send(result);
                    }
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        })
        .map_err(|error| format!("failed to spawn the Windows clipboard thread: {error}"))?;

    ready_rx
        .recv()
        .map_err(|_| "the Windows clipboard thread exited before reporting readiness".to_owned())?
}

/// 创建剪贴板 owner 窗口：0×0、`WS_POPUP`、`WS_EX_TOOLWINDOW`、从不显示。
///
/// 用系统类 `STATIC`：不需要 `RegisterClassW`，也就不需要模块句柄与自定义 WNDPROC，
/// 窗口只负责“作为一个合法的 owner HWND 存在”，不处理任何业务消息。
fn create_owner_window() -> Result<HWND, String> {
    // SAFETY: 类名与窗口名都是静态宽字符串；这是本线程创建的顶层窗口，
    // 不显示（没有 WS_VISIBLE）、不进任务栏（WS_EX_TOOLWINDOW）。
    let window = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            w!("STATIC"),
            w!("HaxShot clipboard owner"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            None,
            None,
        )
    }
    .map_err(|error| {
        format!(
            "CreateWindowExW(STATIC, WS_POPUP) failed: Win32 error {}",
            win32_error_code(&error)
        )
    })?;

    if window.0.is_null() {
        return Err("CreateWindowExW(STATIC, WS_POPUP) returned a null window handle".to_owned());
    }
    Ok(window)
}

/// 抽干本线程的消息队列。
///
/// owner 窗口不需要处理任何业务消息，但创建窗口的线程必须处理消息，否则系统投递
/// （例如 `WM_DESTROYCLIPBOARD`）会一直堆在队列里。
fn pump_thread_messages() {
    let mut message = MSG::default();
    // SAFETY: message 是可写栈变量；hwnd=None 表示“本线程任意窗口的任意消息”；
    // PM_REMOVE 取出即移除，循环不会卡住。
    while unsafe { PeekMessageW(&mut message, None, 0, 0, PM_REMOVE) }.as_bool() {
        // SAFETY: message 由 PeekMessageW 填好，派发给它自己的窗口过程。
        unsafe {
            DispatchMessageW(&message);
        }
    }
}

/// 一次剪贴板会话：`OpenClipboard`（有限重试）→ `EmptyClipboard` → 写两种 DIB → 收尾。
fn write_clipboard(owner: HWND, request: &ClipboardRequest) -> Result<(), String> {
    open_clipboard(owner)?;

    // 无论写入成功与否，每次成功的 OpenClipboard 都必须 CloseClipboard（§33.2）。
    let write_result = write_clipboard_formats(request);
    let close_result = unsafe { CloseClipboard() }.map_err(|error| {
        format!(
            "CloseClipboard failed: Win32 error {}",
            win32_error_code(&error)
        )
    });

    match (write_result, close_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
    }
}

/// 打开剪贴板；被别的进程占着时按 [`OPEN_ATTEMPTS`] / [`OPEN_RETRY_DELAY`] 有限重试。
fn open_clipboard(owner: HWND) -> Result<(), String> {
    let mut last_code = 0u32;
    for attempt in 1..=OPEN_ATTEMPTS {
        // SAFETY: owner 是本线程创建的有效窗口，且本线程在处理消息（隐藏窗口一直活着）。
        match unsafe { OpenClipboard(Some(owner)) } {
            Ok(()) => return Ok(()),
            Err(error) => {
                last_code = win32_error_code(&error);
                if attempt < OPEN_ATTEMPTS {
                    thread::sleep(OPEN_RETRY_DELAY);
                }
            }
        }
    }

    Err(format!(
        "OpenClipboard failed after {OPEN_ATTEMPTS} attempts (~{} ms): Win32 error {last_code}; \
         another process may be holding the clipboard open",
        OPEN_RETRY_DELAY.as_millis() * u128::from(OPEN_ATTEMPTS - 1)
    ))
}

/// 把两种 DIB 依次交给系统；顺序固定为 CF_DIBV5（基线）→ CF_DIB（兼容副本）。
fn write_clipboard_formats(request: &ClipboardRequest) -> Result<(), String> {
    // SAFETY: 剪贴板已经由本次调用打开（owner 是本线程的隐藏窗口），
    // EmptyClipboard 之后 owner 才是写入者。
    unsafe { EmptyClipboard() }.map_err(|error| {
        format!(
            "EmptyClipboard failed: Win32 error {}",
            win32_error_code(&error)
        )
    })?;

    set_clipboard_bytes(CF_DIBV5.0.into(), &request.dib_v5, "CF_DIBV5")?;
    set_clipboard_bytes(CF_DIB.0.into(), &request.dib, "CF_DIB")?;
    Ok(())
}

/// 把一块 DIB 交给系统剪贴板。
///
/// 内存契约（§33.4）：`GlobalAlloc(GMEM_MOVEABLE)`；`SetClipboardData` 成功后所有权归
/// 系统，**不** write、**不** `GlobalFree`；失败则立刻自己释放，不漏内存。
fn set_clipboard_bytes(format: u32, bytes: &[u8], label: &str) -> Result<(), String> {
    let size = bytes.len();
    // SAFETY: GMEM_MOVEABLE 是剪贴板要求的分配方式；size 来自已构造好的缓冲区。
    let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size) }.map_err(|error| {
        format!(
            "GlobalAlloc({size} bytes) for {label} failed: Win32 error {}",
            win32_error_code(&error)
        )
    })?;
    if handle.0.is_null() {
        return Err(format!(
            "GlobalAlloc({size} bytes) for {label} returned a null handle"
        ));
    }

    // SAFETY: handle 是刚分配的可移动内存；GlobalLock 失败时文档承诺设置 last error。
    let locked = unsafe { GlobalLock(handle) };
    if locked.is_null() {
        // SAFETY: 失败后立刻读，中间没有别的会覆盖 last error 的调用。
        let code = unsafe { GetLastError() }.0;
        free_global(handle);
        return Err(format!(
            "GlobalLock for {label} ({size} bytes) failed: Win32 error {code}"
        ));
    }

    // SAFETY: locked 指向 size 字节的可写内存（GlobalLock 成功即保证），bytes 有 size 字节。
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), locked.cast::<u8>(), size);
    }
    // GlobalUnlock 在锁计数归零时返回失败并把 last error 设成 NO_ERROR，这不是错误。
    unsafe {
        let _ = GlobalUnlock(handle);
    }

    // SAFETY: handle 未被释放、未被别的 DC 选中；format 是正确的预定义剪贴板格式。
    match unsafe { SetClipboardData(format, Some(HANDLE(handle.0))) } {
        Ok(_) => Ok(()),
        Err(error) => {
            let code = win32_error_code(&error);
            // 内存还在自己手里，必须释放；除了 GlobalFree 没有别的所有权转移。
            free_global(handle);
            Err(format!(
                "SetClipboardData({label}, {size} bytes) failed: Win32 error {code}"
            ))
        }
    }
}

/// 释放自己持有的全局内存；失败只可能是句柄问题，这里不影响主错误。
fn free_global(handle: HGLOBAL) {
    // SAFETY: handle 来自 GlobalAlloc，且这条路径上没有把它交给系统。
    unsafe {
        let _ = windows::Win32::Foundation::GlobalFree(Some(handle));
    }
}

// ------------------------------------------------------------ PNG → DIB 载荷

/// 已解码的 RGBA8（非预乘）图像。
struct RgbaImage {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
}

/// 两种剪贴板格式的完整字节：CF_DIBV5 与 CF_DIB。
struct DibPayloads {
    dib_v5: Vec<u8>,
    dib: Vec<u8>,
}

/// 把 PNG 解码成 RGBA8。
///
/// 截图链路给的一定是 RGBA8，但这里不假设调用方：调色板 / 灰度 / 16 位先归一化到
/// 8 位再统一成 RGBA，避免“只支持自己产出的 PNG”这种隐性契约。
fn decode_png(data: &[u8]) -> Result<RgbaImage, String> {
    let mut decoder = png::Decoder::new(Cursor::new(data));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder
        .read_info()
        .map_err(|error| format!("failed to read the PNG header: {error}"))?;

    let buffer_size = reader
        .output_buffer_size()
        .ok_or_else(|| "the PNG declares an output size that cannot be represented".to_owned())?;
    let mut buffer = vec![0u8; buffer_size];
    let info = reader
        .next_frame(&mut buffer)
        .map_err(|error| format!("failed to decode the PNG: {error}"))?;
    buffer.truncate(info.buffer_size());

    let width = info.width;
    let height = info.height;
    if width == 0 || height == 0 {
        return Err(format!("the PNG is empty ({width}x{height})"));
    }
    let pixel_count = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .ok_or_else(|| format!("PNG size {width}x{height} overflows the pixel count"))?;

    let mut pixels = Vec::with_capacity(pixel_count * 4);
    match info.color_type {
        png::ColorType::Rgba => pixels = buffer,
        png::ColorType::Rgb => {
            for pixel in buffer.chunks_exact(3) {
                pixels.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
            }
        }
        png::ColorType::Grayscale => {
            for value in buffer.iter() {
                pixels.extend_from_slice(&[*value, *value, *value, 255]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for pixel in buffer.chunks_exact(2) {
                pixels.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]);
            }
        }
        png::ColorType::Indexed => {
            // normalize_to_color8 会展开调色板图；走到这里说明解码器没按契约做。
            return Err("palette PNGs should have been expanded to RGB by the decoder".to_owned());
        }
    }

    if pixels.len() != pixel_count * 4 {
        return Err(format!(
            "decoded {} bytes for a {width}x{height} RGBA image, expected {}",
            pixels.len(),
            pixel_count * 4
        ));
    }

    Ok(RgbaImage {
        pixels,
        width,
        height,
    })
}

/// 组装 CF_DIBV5 与 CF_DIB 的完整体。
///
/// 行方向统一 top-down（负 `biHeight`）：PNG 与抓屏都是这个顺序，不需要翻转；
/// 像素统一 BGRA（32bpp），与 `BITMAPV5HEADER` 里的 R/G/B/A 掩码一致。
fn build_dib_payloads(image: &RgbaImage) -> Result<DibPayloads, String> {
    let width = i32::try_from(image.width)
        .map_err(|_| format!("PNG width {} does not fit into a DIB", image.width))?;
    let height = i32::try_from(image.height)
        .map_err(|_| format!("PNG height {} does not fit into a DIB", image.height))?;
    let stride = image
        .width
        .checked_mul(4)
        .ok_or_else(|| format!("row stride overflow for width {}", image.width))?;
    let size_image = stride
        .checked_mul(image.height)
        .ok_or_else(|| format!("DIB size overflow for {}x{}", image.width, image.height))?;

    let mut bgra = Vec::with_capacity(image.pixels.len());
    for pixel in image.pixels.chunks_exact(4) {
        bgra.extend_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
    }

    let dib_v5_header = BITMAPV5HEADER {
        bV5Size: size_of::<BITMAPV5HEADER>() as u32,
        bV5Width: width,
        // 负高度 = top-down：第一行就是图像上边（§33.4）。
        bV5Height: -height,
        bV5Planes: 1,
        bV5BitCount: 32,
        // BI_BITFIELDS + 下面的掩码：这是 CF_DIBV5 声明 alpha 通道的方式。
        bV5Compression: BI_BITFIELDS,
        bV5SizeImage: size_image,
        bV5RedMask: 0x00FF_0000,
        bV5GreenMask: 0x0000_FF00,
        bV5BlueMask: 0x0000_00FF,
        bV5AlphaMask: 0xFF00_0000,
        bV5CSType: LCS_SRGB,
        bV5Endpoints: CIEXYZTRIPLE::default(),
        ..Default::default()
    };

    let mut dib_v5 = Vec::with_capacity(size_of::<BITMAPV5HEADER>() + bgra.len());
    dib_v5.extend_from_slice(struct_bytes(&dib_v5_header));
    dib_v5.extend_from_slice(&bgra);

    let dib_header = BITMAPINFOHEADER {
        biSize: size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: width,
        biHeight: -height,
        biPlanes: 1,
        biBitCount: 32,
        // BI_RGB：32bpp 不用掩码，GDI 消费者（老工具、部分 IM）都认这个组合。
        biCompression: BI_RGB.0,
        biSizeImage: size_image,
        ..Default::default()
    };

    let mut dib = Vec::with_capacity(size_of::<BITMAPINFOHEADER>() + bgra.len());
    dib.extend_from_slice(struct_bytes(&dib_header));
    dib.extend_from_slice(&bgra);

    Ok(DibPayloads { dib_v5, dib })
}

/// `#[repr(C)]` 的 POD 结构体 → 字节切片。
fn struct_bytes<T>(value: &T) -> &[u8] {
    // SAFETY: T 只能是本模块里的 DIB 头结构体：都是 #[repr(C)] 的纯数据（整数 + 内嵌
    // POD），没有指针，生命周期跟着 value。
    unsafe { std::slice::from_raw_parts(std::ptr::from_ref(value).cast::<u8>(), size_of::<T>()) }
}
