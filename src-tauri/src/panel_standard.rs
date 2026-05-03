use std::sync::OnceLock;
use tauri::{AppHandle, LogicalSize, Manager, Size};
#[cfg(target_os = "windows")]
use tauri::{image::Image, path::BaseDirectory};
#[cfg(not(target_os = "windows"))]
use tauri::{Position, Size as WindowSize};

static INIT_DONE: OnceLock<()> = OnceLock::new();
const PANEL_WIDTH: f64 = 400.0;
const PANEL_HEIGHT_FALLBACK: f64 = 640.0;
const MAX_HEIGHT_FRACTION_OF_MONITOR: f64 = 0.8;

pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
    if INIT_DONE.get().is_some() {
        return Ok(());
    }
    INIT_DONE.set(()).ok();

    if let Some(window) = app_handle.get_webview_window("main") {
        #[cfg(target_os = "windows")]
        if let Err(error) = set_windows_window_icon(app_handle, &window) {
            log::warn!("Failed to set Windows window icon: {}", error);
        }
        #[cfg(target_os = "windows")]
        if let Err(error) = window.set_skip_taskbar(true) {
            log::warn!("Failed to skip Windows taskbar: {}", error);
        }

        window.set_decorations(false)?;
        window.set_resizable(false)?;
        window.set_size(Size::Logical(LogicalSize::new(
            PANEL_WIDTH,
            preferred_panel_height(&window),
        )))?;
        window.center()?;
        window.show()?;
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn set_windows_window_icon(
    app_handle: &AppHandle,
    window: &tauri::WebviewWindow,
) -> tauri::Result<()> {
    let icon_path = app_handle
        .path()
        .resolve("icons/icon.png", BaseDirectory::Resource)?;
    let icon = Image::from_path(icon_path)?;
    window.set_icon(icon)?;
    Ok(())
}

pub fn hide_panel(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        return;
    };

    if let Err(error) = window.hide() {
        log::warn!("Failed to hide window: {}", error);
    }
}

pub fn is_visible(app_handle: &AppHandle) -> bool {
    app_handle
        .get_webview_window("main")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false)
}

pub fn show_panel(app_handle: &AppHandle) {
    show_window(app_handle);
}

pub fn toggle_panel(app_handle: &AppHandle) {
    if is_visible(app_handle) {
        hide_panel(app_handle);
    } else {
        show_panel(app_handle);
    }
}

#[cfg(not(target_os = "windows"))]
pub fn show_panel_at_tray_icon(app_handle: &AppHandle, _icon_position: Position, _icon_size: WindowSize) {
    show_window(app_handle);
}

fn preferred_panel_height(window: &tauri::WebviewWindow) -> f64 {
    window
        .current_monitor()
        .ok()
        .flatten()
        .map(|monitor| {
            let scale = monitor.scale_factor();
            let logical_height = monitor.size().height as f64 / scale;
            logical_height * MAX_HEIGHT_FRACTION_OF_MONITOR
        })
        .filter(|height| height.is_finite() && *height > 0.0)
        .unwrap_or(PANEL_HEIGHT_FALLBACK)
}

fn show_window(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        return;
    };

    if let Err(error) = window.show() {
        log::warn!("Failed to show window: {}", error);
        return;
    }

    if let Err(error) = window.set_focus() {
        log::debug!("Failed to focus window: {}", error);
    }
}
