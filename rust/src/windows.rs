//! Windows 后端：显示器枚举 / 选屏 + 目标元数据 ABI。
//!
//! 这件事只在这里实现一次，C++ / Dart 只消费：
//!
//! - `EnumDisplayMonitors` + `GetMonitorInfoW(MONITORINFOEXW)` 枚举显示器，
//!   `szDevice` → FNV-1a 32 位 display id（[`fnv1a_display_id`]）；
//! - 选屏规则 [`resolve_target_monitor`]：`--display` → 光标所在显示器 → 主显示器；
//! - `hax_shot_target_monitor` / `hax_shot_last_capture_target` 两个元数据导出。
//!
//! GDI 抓屏与冻结语义在下一步实现；剪贴板属于 Phase 5，这里保持可读的“尚未实现”。

use std::collections::HashMap;
use std::mem::size_of;
use std::path::PathBuf;

use windows::core::BOOL;
use windows::Win32::Foundation::{GetLastError, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, MonitorFromPoint, HDC, HMONITOR, MONITORINFOEXW,
    MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, MONITORINFOF_PRIMARY};

use crate::{clear_last_error, set_last_error, HaxShotTargetMonitor};

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
/// `out` 指针为空。
const INVALID_ARGUMENT: i32 = 6;

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

/// 本步骤只完成选屏：真正的 GDI 抓屏在下一步实现，先返回可读失败，
/// 让整条链路可以跑到底但不伪造成功。
pub(crate) fn capture_screen_impl() -> Result<PathBuf, (i32, String)> {
    let requested = requested_display_id();
    let (monitor, source) = resolve_target_monitor(requested)?;
    Err((
        -1,
        format!(
            "backend=gdi requested={requested} source={} display_id={} rect={} size={}x{} dpi={}: GDI capture is not implemented yet",
            source.label(),
            monitor.display_id,
            monitor.rect_label(),
            monitor.width(),
            monitor.height(),
            monitor.dpi
        ),
    ))
}

/// Phase 5 才会实现：写系统图片剪贴板（需要有效的 owner HWND，见 §33）。
pub(crate) fn copy_png_impl(_data: &[u8]) -> Result<(), String> {
    Err("Windows clipboard backend is not implemented yet".to_owned())
}

/// 只查询当前拓扑下本次截图会选中的显示器（requested → 光标 → 主屏），不抓屏。
pub(crate) fn target_monitor_impl(requested: u32, out: *mut HaxShotTargetMonitor) -> i32 {
    if out.is_null() {
        set_last_error("hax_shot_target_monitor: out 指针为空".to_owned());
        return INVALID_ARGUMENT;
    }

    match resolve_target_monitor(requested) {
        Ok((monitor, _source)) => {
            // 只查询，没有本次抓屏：generation 先恒为 0（冻结槽随抓屏实现）。
            clear_last_error();
            // SAFETY: out 非空（上面已判断），调用方按 ABI 分配了完整结构体。
            unsafe {
                std::ptr::write(out, monitor.metadata(0, 0));
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
/// 冻结槽随 GDI 抓屏一起落地；在此之前这里只会返回 `NO_TARGET`。
pub(crate) fn last_capture_target_impl(out: *mut HaxShotTargetMonitor) -> i32 {
    if out.is_null() {
        set_last_error("hax_shot_last_capture_target: out 指针为空".to_owned());
        return INVALID_ARGUMENT;
    }

    // 冻结槽随 GDI 抓屏一起实现：在它落地之前，语义与 Phase 1 一样是“没有目标”。
    set_last_error("hax_shot_last_capture_target: 本进程还没有成功抓屏过".to_owned());
    // SAFETY: out 非空，调用方按 ABI 分配了完整结构体。
    unsafe {
        std::ptr::write(out, invalid_metadata(NO_TARGET));
    }
    NO_TARGET
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

impl MonitorEntry {
    fn width(&self) -> i32 {
        self.rect.right - self.rect.left
    }

    fn height(&self) -> i32 {
        self.rect.bottom - self.rect.top
    }

    fn rect_label(&self) -> String {
        format!(
            "({},{},{},{})",
            self.rect.left, self.rect.top, self.rect.right, self.rect.bottom
        )
    }

    fn metadata(&self, generation: u64, reserved: u32) -> HaxShotTargetMonitor {
        HaxShotTargetMonitor {
            valid: 1,
            error_code: 0,
            display_id: self.display_id,
            reserved,
            left: self.rect.left,
            top: self.rect.top,
            right: self.rect.right,
            bottom: self.rect.bottom,
            width: self.width(),
            height: self.height(),
            dpi: self.dpi,
            generation,
        }
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
