//! Linux 平台后端：Mutter ScreenCast + PipeWire 抓帧，`wl-copy` 写剪贴板。
//!
//! 平台差异只允许留在本模块，Flutter 侧看不到 Mutter / GStreamer / wl-copy。

use futures_util::StreamExt;
use gst::prelude::*;
use gstreamer as gst;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tokio::runtime::Builder;
use tokio::time::{timeout, Duration};
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};

use crate::unique_temp_path;

type MonitorMode = (
    String,
    i32,
    i32,
    f64,
    f64,
    Vec<f64>,
    HashMap<String, OwnedValue>,
);
type Monitor = (
    (String, String, String, String),
    Vec<MonitorMode>,
    HashMap<String, OwnedValue>,
);
type LogicalMonitor = (
    i32,
    i32,
    f64,
    u32,
    bool,
    Vec<(String, String, String, String)>,
    HashMap<String, OwnedValue>,
);

const MUTTER_SCREEN_CAST: &str = "org.gnome.Mutter.ScreenCast";
const MUTTER_SCREEN_CAST_PATH: &str = "/org/gnome/Mutter/ScreenCast";
const MUTTER_SCREEN_CAST_INTERFACE: &str = "org.gnome.Mutter.ScreenCast";
const MUTTER_SESSION_INTERFACE: &str = "org.gnome.Mutter.ScreenCast.Session";
const MUTTER_STREAM_INTERFACE: &str = "org.gnome.Mutter.ScreenCast.Stream";

async fn primary_connector(connection: &Connection) -> Result<String, String> {
    let proxy = Proxy::new(
        connection,
        "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig",
        "org.gnome.Mutter.DisplayConfig",
    )
    .await
    .map_err(|error| format!("failed to connect to Mutter DisplayConfig: {error}"))?;

    let (_, _monitors, logical_monitors, _properties): (
        u32,
        Vec<Monitor>,
        Vec<LogicalMonitor>,
        HashMap<String, OwnedValue>,
    ) = proxy
        .call("GetCurrentState", &())
        .await
        .map_err(|error| format!("failed to read monitor layout from Mutter: {error}"))?;

    logical_monitors
        .iter()
        .find(|monitor| monitor.4 && !monitor.5.is_empty())
        .or_else(|| {
            logical_monitors
                .iter()
                .find(|monitor| !monitor.5.is_empty())
        })
        .and_then(|monitor| monitor.5.first())
        .map(|monitor| monitor.0.clone())
        .ok_or_else(|| "Mutter did not report a primary monitor".to_owned())
}

async fn start_mutter_screencast() -> Result<(Connection, OwnedObjectPath, u32), String> {
    let connection = Connection::session()
        .await
        .map_err(|error| format!("failed to connect to the session bus: {error}"))?;
    let connector = primary_connector(&connection).await?;

    let screen_cast = Proxy::new(
        &connection,
        MUTTER_SCREEN_CAST,
        MUTTER_SCREEN_CAST_PATH,
        MUTTER_SCREEN_CAST_INTERFACE,
    )
    .await
    .map_err(|error| format!("failed to connect to Mutter ScreenCast: {error}"))?;

    let session_options: HashMap<&str, Value<'_>> = HashMap::new();
    let session_path: OwnedObjectPath =
        screen_cast
            .call("CreateSession", &session_options)
            .await
            .map_err(|error| format!("Mutter ScreenCast session creation failed: {error}"))?;

    let session = Proxy::new(
        &connection,
        MUTTER_SCREEN_CAST,
        session_path.as_str(),
        MUTTER_SESSION_INTERFACE,
    )
    .await
    .map_err(|error| format!("failed to connect to Mutter ScreenCast session: {error}"))?;

    let mut monitor_options: HashMap<&str, Value<'_>> = HashMap::new();
    // The cursor is handled by the Flutter UI and is not part of the image.
    monitor_options.insert("cursor-mode", Value::U32(0));
    let stream_path: OwnedObjectPath = session
        .call("RecordMonitor", &(connector.as_str(), monitor_options))
        .await
        .map_err(|error| format!("Mutter monitor recording setup failed: {error}"))?;

    let stream = Proxy::new(
        &connection,
        MUTTER_SCREEN_CAST,
        stream_path.as_str(),
        MUTTER_STREAM_INTERFACE,
    )
    .await
    .map_err(|error| format!("failed to connect to Mutter ScreenCast stream: {error}"))?;
    let mut stream_signals = stream
        .receive_signal("PipeWireStreamAdded")
        .await
        .map_err(|error| format!("failed to subscribe to Mutter PipeWire stream: {error}"))?;

    session
        .call_method("Start", &())
        .await
        .map_err(|error| format!("Mutter ScreenCast start failed: {error}"))?;

    let message = timeout(Duration::from_secs(10), stream_signals.next())
        .await
        .map_err(|_| "timed out waiting for Mutter PipeWire stream".to_owned())?
        .ok_or_else(|| "Mutter PipeWire stream ended before it was created".to_owned())?;
    let (node_id,): (u32,) = message
        .body()
        .deserialize()
        .map_err(|error| format!("invalid Mutter PipeWire stream signal: {error}"))?;

    Ok((connection, session_path, node_id))
}

async fn stop_mutter_screencast(connection: &Connection, session_path: &OwnedObjectPath) {
    if let Ok(session) = Proxy::new(
        connection,
        MUTTER_SCREEN_CAST,
        session_path.as_str(),
        MUTTER_SESSION_INTERFACE,
    )
    .await
    {
        let _ = session.call_method("Stop", &()).await;
    }
}

fn capture_pipewire_frame(node_id: u32) -> Result<PathBuf, String> {
    gst::init().map_err(|error| format!("failed to initialize GStreamer: {error}"))?;

    let destination = unique_temp_path();
    let source = gst::ElementFactory::make("pipewiresrc")
        .property("path", node_id.to_string())
        .property("num-buffers", 1i32)
        .build()
        .map_err(|error| format!("failed to create GStreamer pipewiresrc: {error}"))?;
    let converter = gst::ElementFactory::make("videoconvert")
        .build()
        .map_err(|error| format!("failed to create GStreamer videoconvert: {error}"))?;
    let encoder = gst::ElementFactory::make("pngenc")
        .build()
        .map_err(|error| format!("failed to create GStreamer pngenc: {error}"))?;
    let sink = gst::ElementFactory::make("filesink")
        .property("location", destination.to_string_lossy().as_ref())
        .build()
        .map_err(|error| format!("failed to create GStreamer filesink: {error}"))?;

    let pipeline = gst::Pipeline::new();
    pipeline
        .add_many([&source, &converter, &encoder, &sink])
        .map_err(|error| format!("failed to assemble capture pipeline: {error}"))?;
    gst::Element::link_many([&source, &converter, &encoder, &sink])
        .map_err(|error| format!("failed to link capture pipeline: {error}"))?;

    let result = (|| {
        pipeline
            .set_state(gst::State::Playing)
            .map_err(|error| format!("failed to start GStreamer capture: {error:?}"))?;
        let bus = pipeline
            .bus()
            .ok_or_else(|| "GStreamer capture pipeline has no bus".to_owned())?;
        let message = bus
            .timed_pop_filtered(
                gst::ClockTime::from_seconds(10),
                &[gst::MessageType::Eos, gst::MessageType::Error],
            )
            .ok_or_else(|| "timed out waiting for GStreamer capture frame".to_owned())?;

        match message.view() {
            gst::MessageView::Eos(..) => Ok(()),
            gst::MessageView::Error(error) => Err(format!(
                "GStreamer capture failed: {}{}",
                error.error(),
                error
                    .debug()
                    .map(|debug| format!(" ({debug})"))
                    .unwrap_or_default()
            )),
            _ => Err("GStreamer capture ended unexpectedly".to_owned()),
        }
    })();
    let _ = pipeline.set_state(gst::State::Null);

    if let Err(error) = result {
        let _ = fs::remove_file(&destination);
        return Err(error);
    }
    if !destination.is_file() {
        return Err("GStreamer produced no screenshot PNG".to_owned());
    }
    Ok(destination)
}

/// Linux 没有 macOS 那种屏幕录制授权，始终允许。
pub(crate) fn screen_capture_authorized_impl() -> u32 {
    1
}

/// Linux 不需要请求授权。
pub(crate) fn request_screen_capture_access_impl() -> u32 {
    1
}

/// 返回 (ABI 错误码, 错误信息)。Linux 只有“失败”这一种码。
pub(crate) fn capture_screen_impl() -> Result<PathBuf, (i32, String)> {
    capture_screen_inner().map_err(|error| (-1, error))
}

fn capture_screen_inner() -> Result<PathBuf, String> {
    let runtime = Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("failed to create async runtime: {error}"))?;

    let (connection, session_path, node_id) = runtime.block_on(start_mutter_screencast())?;
    let capture_result = capture_pipewire_frame(node_id);
    runtime.block_on(stop_mutter_screencast(&connection, &session_path));
    capture_result
}

pub(crate) fn copy_png_impl(data: &[u8]) -> Result<(), String> {
    if data.is_empty() {
        return Err("PNG data is empty".to_owned());
    }

    // GNOME's Wayland compositor does not expose the data-control protocol
    // required by wl-clipboard-rs. The official wl-copy client uses the
    // compositor-compatible clipboard path, so use it as the MVP backend.
    let mut child = Command::new("wl-copy")
        .args(["--type", "image/png"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("failed to start wl-copy: {error}"))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "wl-copy stdin is unavailable".to_owned())?;
    stdin
        .write_all(data)
        .map_err(|error| format!("failed to write PNG to wl-copy: {error}"))?;
    drop(stdin);

    let status = child
        .wait()
        .map_err(|error| format!("failed to wait for wl-copy: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("wl-copy exited with status {status}"))
    }
}

/// GNOME Wayland 不向客户端提供全局指针位置，因此无法判断用户在哪个显示器上。
///
/// 托盘宿主拿到 0 就不会给 `--capture` 传显示器参数，截图仍然使用主显示器。
pub(crate) fn cursor_display_impl() -> u32 {
    0
}
