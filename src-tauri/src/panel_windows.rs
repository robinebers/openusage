use tauri::{AppHandle, Manager, Position, Size};

fn main_window(app_handle: &AppHandle) -> Option<tauri::WebviewWindow> {
    app_handle.get_webview_window("main")
}

pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = main_window(app_handle) {
        window.hide()?;
    }
    Ok(())
}

pub fn show_panel(app_handle: &AppHandle) {
    let Some(window) = main_window(app_handle) else {
        return;
    };

    if let Err(error) = window.show() {
        log::warn!("Failed to show window: {}", error);
        return;
    }

    if let Err(error) = window.set_focus() {
        log::warn!("Failed to focus window: {}", error);
    }
}

pub fn hide_panel(app_handle: &AppHandle) {
    let Some(window) = main_window(app_handle) else {
        return;
    };

    if let Err(error) = window.hide() {
        log::warn!("Failed to hide window: {}", error);
    }
}

pub fn is_visible(app_handle: &AppHandle) -> bool {
    main_window(app_handle)
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false)
}

pub fn toggle_panel(app_handle: &AppHandle) {
    if is_visible(app_handle) {
        hide_panel(app_handle);
    } else {
        show_panel(app_handle);
    }
}

pub fn position_panel_at_tray_icon(
    _app_handle: &AppHandle,
    _icon_position: Position,
    _icon_size: Size,
) {
}
