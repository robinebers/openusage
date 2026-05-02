use std::sync::OnceLock;
use tauri::{AppHandle, Manager};
#[cfg(not(target_os = "windows"))]
use tauri::{Position, Size};

static INIT_DONE: OnceLock<()> = OnceLock::new();

pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
    if INIT_DONE.get().is_some() {
        return Ok(());
    }
    INIT_DONE.set(()).ok();

    if let Some(window) = app_handle.get_webview_window("main") {
        window.set_decorations(true)?;
        window.set_resizable(false)?;
        window.center()?;
        window.show()?;
    }

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
pub fn show_panel_at_tray_icon(app_handle: &AppHandle, _icon_position: Position, _icon_size: Size) {
    show_window(app_handle);
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
