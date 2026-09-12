//! Hax Shot 原生层：Flutter 通过 `dart:ffi` 只看到下面这几个 C ABI 函数。
//!
//! 平台实现分别放在 `linux` 和 `macos` 模块里，Flutter 侧看不到
//! Mutter / PipeWire / CoreGraphics 这些平台细节。

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

use std::cell::Cell;
use std::cmp::min;
use std::io::Write;
use std::path::PathBuf;
use std::ptr;
use std::rc::Rc;
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
    screen_capture_authorized_impl, target_display_id_impl,
};

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

/// 解析本次截图的目标显示器，返回 `CGDirectDisplayID`。
///
/// 供 macOS Runner 的 Swift 把冻结画面浮层摆到抓屏用的那块屏上；规则与抓屏
/// （[`hax_shot_capture_screen`]）共用 `macos::resolve_target_display` 这一份实现，
/// 两边不会再各自维护一套候选顺序。`requested` 由调用方从 `--display <id>` 解析，
/// 拿不到时传 0。
///
/// 只在 macOS 编译：Linux 的窗口摆位完全由 Flutter 负责，没有这个概念。
#[cfg(target_os = "macos")]
#[no_mangle]
pub extern "C" fn hax_shot_target_display(requested: u32) -> u32 {
    target_display_id_impl(requested)
}

/// Capture one frame of the target display and write it to a temporary PNG.
///
/// The target display is `--display <id>` when the tray host passed one, then the
/// display under the pointer, then the main display (see `rust/src/macos.rs`).
/// The Runner calls [`hax_shot_target_display`] to place the overlay on the same
/// display, so both paths share one rule.
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
///
/// # Safety
///
/// `data` 必须指向 `length` 个可读字节。C ABI 无法在 Rust 侧校验，所以调用方
/// （Dart）负责保证；标记为 `unsafe` 是诚实地表达这个约定。
#[no_mangle]
pub unsafe extern "C" fn hax_shot_copy_png_to_clipboard(data: *const u8, length: usize) -> i32 {
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

/// 编码 PNG 时输出缓冲区需要的容量上界。
///
/// PNG 理论上可能比原始像素略大：deflate 在不可压缩数据上有极小膨胀，每行还有一个
/// filter 字节，再加块头和结束标记。这里给一个宽松上界，调用方按它分配就一定够
/// （实测输出通常只有原始像素的 10%~30%）。
/// 返回 0 表示尺寸大到无法表示（u32 x u32 x 4 会溢出 u64）。
fn png_buffer_size(width: u32, height: u32) -> u64 {
    let Some(pixels) = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|count| count.checked_mul(4))
    else {
        return 0;
    };
    pixels
        .saturating_add(pixels / 64)
        .saturating_add(u64::from(height))
        .saturating_add(1024)
}

/// [`png_buffer_size`] 的 C ABI 版本，给 Flutter 侧算缓冲区大小用。
#[no_mangle]
pub extern "C" fn hax_shot_png_buffer_size(width: u32, height: u32) -> u64 {
    png_buffer_size(width, height)
}

/// 把 RGBA8 像素编码成 PNG。
///
/// 用 `png` crate 的 [`png::Compression::Fast`]（底层是 fdeflate，专为 PNG 调过的
/// deflate 实现），比 Skia 的 `Image.toByteData(png)`（zlib level 6）快数倍，代价是
/// 体积大一些。对截图是划算的：保存/复制都发生在浮层收起之后，用户看不到等待。
///
/// 返回写入的字节数；-1 失败，-2 输出缓冲区不足（按 [`hax_shot_png_buffer_size`]
/// 的返回值分配就不会出现）。
///
/// # Safety
///
/// `pixels` 必须指向 `width * height * 4` 个可读字节，`output` 必须指向 `capacity`
/// 个可写字节。C ABI 无法在 Rust 侧校验，由调用方（Dart）保证。
#[no_mangle]
pub unsafe extern "C" fn hax_shot_encode_png(
    pixels: *const u8,
    width: u32,
    height: u32,
    output: *mut u8,
    capacity: usize,
) -> i32 {
    clear_last_error();

    if pixels.is_null() {
        set_last_error("encode_png: 像素指针为空".to_owned());
        return -1;
    }
    if output.is_null() || capacity == 0 {
        set_last_error("encode_png: 输出缓冲区为空".to_owned());
        return -2;
    }
    if width == 0 || height == 0 {
        set_last_error("encode_png: 尺寸为 0".to_owned());
        return -1;
    }
    let required = png_buffer_size(width, height);
    if required == 0 {
        set_last_error("encode_png: 尺寸大到无法表示".to_owned());
        return -1;
    }
    if (capacity as u64) < required {
        set_last_error(format!("encode_png: 输出缓冲区不足，需要 {required} 字节"));
        return -2;
    }

    let Some(length) = (width as usize)
        .checked_mul(height as usize)
        .and_then(|count| count.checked_mul(4))
    else {
        set_last_error("encode_png: 像素尺寸溢出".to_owned());
        return -1;
    };

    // SAFETY: 调用方保证 pixels 指向 length 个可读字节、output 指向 capacity 个可写字节。
    let source = unsafe { std::slice::from_raw_parts(pixels, length) };
    let destination = unsafe { std::slice::from_raw_parts_mut(output, capacity) };

    // `&mut [u8]` 本身不是 UnwindSafe，但这里只是编码，panic 后不会再碰这块内存。
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        encode_png_impl(source, width, height, destination)
    }));
    match result {
        Ok(Ok(written)) => {
            if written > i32::MAX as usize {
                set_last_error(format!("encode_png: PNG 过大（{written} 字节）"));
                return -1;
            }
            written as i32
        }
        Ok(Err(PngEncodeError::BufferTooSmall)) => {
            set_last_error("encode_png: 输出缓冲区不足".to_owned());
            -2
        }
        Ok(Err(PngEncodeError::Failed(message))) => {
            set_last_error(message);
            -1
        }
        Err(_) => {
            set_last_error("encode_png: 原生编码 panic".to_owned());
            -1
        }
    }
}

#[derive(Debug)]
enum PngEncodeError {
    BufferTooSmall,
    Failed(String),
}

/// 把编码结果写进调用方给的缓冲区，并记下实际写了多少字节。
///
/// `png` 的 `Writer::finish` 不会把 writer 还回来，所以用 `Rc<Cell<usize>>` 共享计数。
struct BufferWriter<'a> {
    buffer: &'a mut [u8],
    written: Rc<Cell<usize>>,
}

impl Write for BufferWriter<'_> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        let start = self.written.get();
        let end = start + data.len();
        if end > self.buffer.len() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "png output buffer is too small",
            ));
        }
        self.buffer[start..end].copy_from_slice(data);
        self.written.set(end);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn encode_png_impl(
    source: &[u8],
    width: u32,
    height: u32,
    destination: &mut [u8],
) -> Result<usize, PngEncodeError> {
    let written = Rc::new(Cell::new(0));
    let mut encoder = png::Encoder::new(
        BufferWriter {
            buffer: destination,
            written: Rc::clone(&written),
        },
        width,
        height,
    );
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);

    let mut writer = encoder.write_header().map_err(map_encode_error)?;
    let encoded = writer.write_image_data(source).map_err(map_encode_error);
    // finish() 之前也要保证写完整，否则调用方拿到的 PNG 是不完整的。
    let finished = writer.finish().map_err(map_encode_error);
    encoded?;
    finished?;
    Ok(written.get())
}

fn map_encode_error(error: png::EncodingError) -> PngEncodeError {
    if let png::EncodingError::IoError(io_error) = &error {
        if io_error.kind() == std::io::ErrorKind::WriteZero {
            return PngEncodeError::BufferTooSmall;
        }
    }
    PngEncodeError::Failed(format!("PNG 编码失败：{error}"))
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 渐变 + 色块，接近截图里 UI 和文字的分布，比纯随机像素更贴近实际。
    fn sample_pixels(width: u32, height: u32) -> Vec<u8> {
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            for x in 0..width {
                let block = (x / 7 + y / 5) % 3 == 0;
                let base = (x * 255 / width.max(1)) as u8;
                pixels.extend_from_slice(&[
                    base,
                    if block {
                        0x20
                    } else {
                        (y * 255 / height.max(1)) as u8
                    },
                    if block { 0xD0 } else { 0x80 },
                    0xFF,
                ]);
            }
        }
        pixels
    }

    fn encode(pixels: &[u8], width: u32, height: u32) -> Vec<u8> {
        let mut output = vec![0u8; png_buffer_size(width, height) as usize];
        let written = encode_png_impl(pixels, width, height, &mut output).expect("编码失败");
        output.truncate(written);
        output
    }

    fn decode(png_bytes: &[u8]) -> (u32, u32, Vec<u8>) {
        let mut decoder = png::Decoder::new(std::io::Cursor::new(png_bytes));
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info().expect("解码失败");
        let mut buffer = vec![0; reader.output_buffer_size().expect("输出过大")];
        let info = reader.next_frame(&mut buffer).expect("读取帧失败");
        assert_eq!(info.color_type, png::ColorType::Rgba);
        assert_eq!(info.bit_depth, png::BitDepth::Eight);
        buffer.truncate(info.buffer_size());
        (info.width, info.height, buffer)
    }

    #[test]
    fn png_round_trip_preserves_pixels() {
        let (width, height) = (37, 23);
        let pixels = sample_pixels(width, height);

        let (decoded_width, decoded_height, decoded) = decode(&encode(&pixels, width, height));

        assert_eq!((decoded_width, decoded_height), (width, height));
        assert_eq!(decoded, pixels);
    }

    #[test]
    fn png_output_is_smaller_than_the_raw_pixels() {
        let (width, height) = (240, 160);
        let pixels = sample_pixels(width, height);
        let encoded = encode(&pixels, width, height);

        assert!(
            encoded.len() < pixels.len(),
            "PNG {} 字节不应大于原始像素 {} 字节",
            encoded.len(),
            pixels.len()
        );
        assert!(encoded.len() as u64 <= png_buffer_size(width, height));
    }

    #[test]
    fn png_buffer_size_rejects_impossible_dimensions() {
        // u32::MAX x u32::MAX x 4 会溢出 u64，必须返回 0 而不是 wrap 成一个小值。
        assert_eq!(png_buffer_size(u32::MAX, u32::MAX), 0);
        assert!(png_buffer_size(3024, 1964) > 0);
    }

    #[test]
    fn png_buffer_size_leaves_room_for_the_filter_bytes() {
        // 每行一个 filter 字节 + 头尾开销，1/64 的余量足够覆盖 deflate 的膨胀。
        let (width, height) = (3024, 1964);
        let raw = u64::from(width) * u64::from(height) * 4;
        assert!(png_buffer_size(width, height) >= raw + u64::from(height));
    }

    /// 调参用：`HAX_PNG_BENCH=/tmp/x.png cargo test --release -- --ignored --nocapture`
    ///
    /// 拿一张真实截图（任何 PNG）比较不同压缩/滤镜组合的耗时和体积，用来决定
    /// `encode_png_impl` 里的参数。
    #[test]
    #[ignore = "手动跑的 PNG 编码调参基准"]
    fn png_encode_bench() {
        let Ok(path) = std::env::var("HAX_PNG_BENCH") else {
            println!("设置 HAX_PNG_BENCH=<png 路径> 才有输入");
            return;
        };
        let file = std::fs::read(&path).expect("读取基准输入失败");
        let mut decoder = png::Decoder::new(std::io::Cursor::new(file.as_slice()));
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info().expect("解码基准输入失败");
        let mut pixels = vec![0; reader.output_buffer_size().expect("输出过大")];
        let info = reader.next_frame(&mut pixels).expect("读取基准帧失败");
        pixels.truncate(info.buffer_size());
        let (width, height) = (info.width, info.height);
        let pixels = match info.color_type {
            png::ColorType::Rgba => pixels,
            png::ColorType::Rgb => pixels
                .chunks_exact(3)
                .flat_map(|pixel| [pixel[0], pixel[1], pixel[2], 0xFF])
                .collect(),
            other => {
                println!("基准输入是 {other:?}，跳过");
                return;
            }
        };
        println!(
            "基准输入 {width}x{height}，原始像素 {}KB",
            pixels.len() / 1024
        );

        let options = [
            ("Fast+Adaptive", png::Compression::Fast, None),
            ("Fast+Sub", png::Compression::Fast, Some(png::Filter::Sub)),
            ("Fast+Up", png::Compression::Fast, Some(png::Filter::Up)),
            (
                "Fast+Paeth",
                png::Compression::Fast,
                Some(png::Filter::Paeth),
            ),
            (
                "Fast+NoFilter",
                png::Compression::Fast,
                Some(png::Filter::NoFilter),
            ),
            ("Balanced", png::Compression::Balanced, None),
            ("High", png::Compression::High, None),
        ];
        for (name, compression, filter) in options {
            let mut output = vec![0u8; png_buffer_size(width, height) as usize];
            let mut encoder = png::Encoder::new(output.as_mut_slice(), width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.set_compression(compression);
            if let Some(filter) = filter {
                encoder.set_filter(filter);
            }
            let watch = std::time::Instant::now();
            let mut writer = encoder.write_header().expect("写头失败");
            writer.write_image_data(&pixels).expect("写数据失败");
            writer.finish().expect("收尾失败");
            let elapsed = watch.elapsed();
            let size = output
                .iter()
                .rposition(|byte| *byte != 0)
                .map_or(0, |index| index + 1);
            println!(
                "  {name:16} {:>7.1}ms  {:>7}KB",
                elapsed.as_secs_f64() * 1000.0,
                size / 1024
            );
        }
    }
}
