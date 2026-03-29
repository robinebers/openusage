use std::sync::OnceLock;

use tauri::window::Monitor;
use tauri::{AppHandle, Manager, Position, Size, WebviewWindow, WindowEvent};

const PANEL_GAP: f64 = 12.0;

#[derive(Debug, Clone, Copy, PartialEq)]
struct PanelPlacement {
    x: f64,
    y: f64,
}

#[derive(Debug, Clone, Copy)]
struct PhysicalRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn main_window(app_handle: &AppHandle) -> Option<WebviewWindow> {
    app_handle.get_webview_window("main")
}

fn blur_handler_registered() -> &'static OnceLock<()> {
    static REGISTERED: OnceLock<()> = OnceLock::new();
    &REGISTERED
}

fn physical_position_components(position: &Position) -> (f64, f64) {
    match position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    }
}

fn physical_size_components(size: &Size) -> (f64, f64) {
    match size {
        Size::Physical(size) => (size.width as f64, size.height as f64),
        Size::Logical(size) => (size.width, size.height),
    }
}

fn panel_size(window: &WebviewWindow, monitor_scale_factor: f64) -> (f64, f64) {
    match window.outer_size() {
        Ok(size) => (size.width as f64, size.height as f64),
        Err(_) => {
            let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
                .expect("tauri.conf.json must be valid JSON");
            let configured_width = conf["app"]["windows"][0]["width"]
                .as_f64()
                .expect("width must be set in tauri.conf.json");
            let configured_height = conf["app"]["windows"][0]["height"]
                .as_f64()
                .expect("height must be set in tauri.conf.json");

            (
                configured_width * monitor_scale_factor,
                configured_height * monitor_scale_factor,
            )
        }
    }
}

fn monitor_work_area_rect(monitor: &Monitor) -> PhysicalRect {
    let work_area = monitor.work_area();
    PhysicalRect {
        x: work_area.position.x as f64,
        y: work_area.position.y as f64,
        width: work_area.size.width as f64,
        height: work_area.size.height as f64,
    }
}

fn calculate_panel_position(
    icon_x: f64,
    icon_y: f64,
    icon_width: f64,
    icon_height: f64,
    panel_width: f64,
    panel_height: f64,
    work_area_x: f64,
    work_area_y: f64,
    work_area_width: f64,
    work_area_height: f64,
) -> PanelPlacement {
    let work_area_right = work_area_x + work_area_width;
    let work_area_bottom = work_area_y + work_area_height;

    let centered_x = icon_x + (icon_width / 2.0) - (panel_width / 2.0);
    let max_x = (work_area_right - panel_width).max(work_area_x);
    let clamped_x = centered_x.clamp(work_area_x, max_x);

    let preferred_below_y = icon_y + icon_height + PANEL_GAP;
    let preferred_above_y = icon_y - panel_height - PANEL_GAP;
    let fits_below = preferred_below_y + panel_height <= work_area_bottom;
    let fits_above = preferred_above_y >= work_area_y;

    let y = if fits_below {
        preferred_below_y
    } else if fits_above {
        preferred_above_y
    } else {
        let max_y = (work_area_bottom - panel_height).max(work_area_y);
        preferred_above_y.clamp(work_area_y, max_y)
    };

    PanelPlacement { x: clamped_x, y }
}

pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
    let Some(window) = main_window(app_handle) else {
        log::error!("main window not available during panel init");
        return Ok(());
    };

    window.set_skip_taskbar(true)?;
    window.set_always_on_top(true)?;
    let _ = window.set_shadow(false);
    if blur_handler_registered().set(()).is_ok() {
        let handle = app_handle.clone();
        window.on_window_event(move |event| {
            if matches!(event, WindowEvent::Focused(false)) {
                hide_panel(&handle);
            }
        });
    }

    Ok(())
}

pub fn show_panel(app_handle: &AppHandle) {
    let Some(window) = main_window(app_handle) else {
        log::error!("main window not available while showing panel");
        return;
    };

    if let Err(err) = init(app_handle) {
        log::error!("Failed to initialize panel state: {}", err);
        return;
    }

    let _ = window.unminimize();
    if let Err(err) = window.show() {
        log::error!("Failed to show panel: {}", err);
        return;
    }

    if let Err(err) = window.set_focus() {
        log::warn!("Failed to focus panel: {}", err);
    }
}

pub fn hide_panel(app_handle: &AppHandle) {
    let Some(window) = main_window(app_handle) else {
        log::error!("main window not available while hiding panel");
        return;
    };

    if let Err(err) = window.hide() {
        log::warn!("Failed to hide panel: {}", err);
    }
}

pub fn toggle_panel(app_handle: &AppHandle) {
    let Some(window) = main_window(app_handle) else {
        log::error!("main window not available while toggling panel");
        return;
    };

    match window.is_visible() {
        Ok(true) => {
            log::debug!("toggle_panel: hiding panel");
            hide_panel(app_handle);
        }
        Ok(false) => {
            log::debug!("toggle_panel: showing panel");
            show_panel(app_handle);
        }
        Err(err) => {
            log::warn!("Failed to read panel visibility: {}", err);
            show_panel(app_handle);
        }
    }
}

pub fn position_panel_at_tray_icon(
    app_handle: &AppHandle,
    icon_position: Position,
    icon_size: Size,
) {
    let Some(window) = main_window(app_handle) else {
        log::error!("main window not available while positioning panel");
        return;
    };

    let (icon_x, icon_y) = physical_position_components(&icon_position);
    let (icon_width, icon_height) = physical_size_components(&icon_size);
    let icon_center_x = icon_x + (icon_width / 2.0);
    let icon_center_y = icon_y + (icon_height / 2.0);

    let monitor = match window
        .monitor_from_point(icon_center_x, icon_center_y)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten())
    {
        Some(monitor) => monitor,
        None => {
            log::warn!("No monitor found while positioning panel");
            return;
        }
    };

    let work_area = monitor_work_area_rect(&monitor);
    let (panel_width, panel_height) = panel_size(&window, monitor.scale_factor());
    let placement = calculate_panel_position(
        icon_x,
        icon_y,
        icon_width,
        icon_height,
        panel_width,
        panel_height,
        work_area.x,
        work_area.y,
        work_area.width,
        work_area.height,
    );

    if let Err(err) = window.set_position(tauri::PhysicalPosition::new(
        placement.x.round() as i32,
        placement.y.round() as i32,
    )) {
        log::warn!("Failed to position panel: {}", err);
    }
}

#[cfg(test)]
mod tests {
    use super::{PanelPlacement, calculate_panel_position};

    #[test]
    fn positions_panel_above_bottom_tray_icons_and_clamps_right_edge() {
        let placement = calculate_panel_position(
            1840.0, 1040.0, 24.0, 24.0, 400.0, 500.0, 0.0, 0.0, 1920.0, 1080.0,
        );

        assert_eq!(
            placement,
            PanelPlacement {
                x: 1520.0,
                y: 528.0,
            }
        );
    }

    #[test]
    fn positions_panel_below_top_tray_icons_and_clamps_left_edge() {
        let placement = calculate_panel_position(
            8.0, 10.0, 24.0, 24.0, 400.0, 500.0, 0.0, 0.0, 1920.0, 1080.0,
        );

        assert_eq!(placement, PanelPlacement { x: 0.0, y: 46.0 });
    }
}
