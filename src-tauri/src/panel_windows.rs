use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager, PhysicalPosition, Position, Size, WindowEvent};

static FOCUS_HANDLER_INSTALLED: AtomicBool = AtomicBool::new(false);

struct PanelLayout {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn panel_layout_for_window(window: &tauri::WebviewWindow) -> PanelLayout {
    let panel_size = window.outer_size().ok();
    let conf: serde_json::Value =
        serde_json::from_str(include_str!("../tauri.conf.json")).expect("tauri.conf.json is valid");
    let fallback_scale = window
        .scale_factor()
        .ok()
        .or_else(|| {
            window
                .current_monitor()
                .ok()
                .flatten()
                .map(|monitor| monitor.scale_factor())
        })
        .unwrap_or(1.0);
    let fallback_width =
        conf["app"]["windows"][0]["width"].as_f64().unwrap_or(400.0) * fallback_scale;
    let fallback_height = conf["app"]["windows"][0]["height"]
        .as_f64()
        .unwrap_or(500.0)
        * fallback_scale;

    PanelLayout {
        x: 0.0,
        y: 0.0,
        width: panel_size
            .as_ref()
            .map(|size| size.width as f64)
            .unwrap_or(fallback_width),
        height: panel_size
            .as_ref()
            .map(|size| size.height as f64)
            .unwrap_or(fallback_height),
    }
}

fn work_area_layout(monitor: &tauri::Monitor) -> PanelLayout {
    let work_area = monitor.work_area();
    PanelLayout {
        x: work_area.position.x as f64,
        y: work_area.position.y as f64,
        width: work_area.size.width as f64,
        height: work_area.size.height as f64,
    }
}

fn monitor_layout(monitor: &tauri::Monitor) -> PanelLayout {
    let position = monitor.position();
    let size = monitor.size();
    PanelLayout {
        x: position.x as f64,
        y: position.y as f64,
        width: size.width as f64,
        height: size.height as f64,
    }
}

fn contains_point(layout: &PanelLayout, point_x: f64, point_y: f64) -> bool {
    point_x >= layout.x
        && point_x < layout.x + layout.width
        && point_y >= layout.y
        && point_y < layout.y + layout.height
}

fn set_window_position(window: &tauri::WebviewWindow, panel_x: f64, panel_y: f64) {
    if let Err(error) = window.set_position(Position::Physical(PhysicalPosition {
        x: panel_x.round() as i32,
        y: panel_y.round() as i32,
    })) {
        log::warn!("Failed to position panel: {}", error);
    }
}

fn position_panel_from_tray(app_handle: &AppHandle) {
    let Some(tray) = app_handle.tray_by_id("tray") else {
        log::debug!("position_panel_from_tray: tray icon not found");
        position_panel_at_taskbar(app_handle);
        return;
    };

    match tray.rect() {
        Ok(Some(rect)) => position_panel_at_tray_icon(app_handle, rect.position, rect.size),
        Ok(None) => {
            log::debug!("position_panel_from_tray: tray rect not available yet");
            position_panel_at_taskbar(app_handle);
        }
        Err(error) => {
            log::warn!(
                "position_panel_from_tray: failed to get tray rect: {}",
                error
            );
            position_panel_at_taskbar(app_handle);
        }
    }
}

pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app_handle.get_webview_window("main") {
        if let Err(error) = window.set_shadow(false) {
            log::debug!("Failed to disable Windows panel shadow: {}", error);
        }

        if FOCUS_HANDLER_INSTALLED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            let handle = app_handle.clone();
            window.on_window_event(move |event| {
                if matches!(event, WindowEvent::Focused(false)) && is_panel_visible(&handle) {
                    hide_panel(&handle);
                }
            });
        }

        Ok(())
    } else {
        Err(tauri::Error::WindowNotFound)
    }
}

pub fn hide_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        if let Err(error) = window.hide() {
            log::warn!("Failed to hide panel: {}", error);
        }
    }
}

pub fn is_panel_visible(app_handle: &AppHandle) -> bool {
    app_handle
        .get_webview_window("main")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false)
}

pub fn show_panel(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        log::error!("Panel window missing");
        return;
    };

    if let Err(error) = window.set_shadow(false) {
        log::debug!("Failed to disable Windows panel shadow: {}", error);
    }

    position_panel_from_tray(app_handle);

    if let Err(error) = window.show() {
        log::warn!("Failed to show panel: {}", error);
        return;
    }

    if let Err(error) = window.set_focus() {
        log::debug!("Failed to focus panel: {}", error);
    }
}

pub fn toggle_panel(app_handle: &AppHandle) {
    if is_panel_visible(app_handle) {
        hide_panel(app_handle);
    } else {
        show_panel(app_handle);
    }
}

pub fn position_panel_at_tray_icon(
    app_handle: &AppHandle,
    icon_position: Position,
    icon_size: Size,
) {
    let Some(window) = app_handle.get_webview_window("main") else {
        log::error!("Panel window missing");
        return;
    };

    let (icon_phys_x, icon_phys_y) = match icon_position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    };
    let (icon_phys_w, icon_phys_h) = match icon_size {
        Size::Physical(size) => (size.width as f64, size.height as f64),
        Size::Logical(size) => (size.width, size.height),
    };

    let Ok(monitors) = window.available_monitors() else {
        log::warn!("Failed to get monitors for panel positioning");
        return;
    };

    let icon_center_x = icon_phys_x + (icon_phys_w / 2.0);
    let icon_center_y = icon_phys_y + (icon_phys_h / 2.0);

    let monitor = monitors
        .iter()
        .find(|monitor| {
            let bounds = monitor_layout(monitor);
            contains_point(&bounds, icon_center_x, icon_center_y)
        })
        .cloned()
        .or_else(|| window.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        log::warn!("No monitor available for panel positioning");
        return;
    };

    let panel = panel_layout_for_window(&window);
    let work_area = work_area_layout(&monitor);
    let gap = 12.0;

    let icon_near_bottom = icon_center_y > work_area.y + (work_area.height * 0.7);
    let icon_near_top = icon_center_y < work_area.y + (work_area.height * 0.3);
    if !icon_near_bottom && !icon_near_top {
        position_panel_at_taskbar(app_handle);
        return;
    }

    let desired_x = icon_center_x - (panel.width / 2.0);
    let desired_y = if icon_near_bottom {
        icon_phys_y - panel.height - gap
    } else {
        icon_phys_y + icon_phys_h + gap
    };

    let max_x = work_area.x + work_area.width - panel.width;
    let max_y = work_area.y + work_area.height - panel.height;
    let panel_x = desired_x.clamp(work_area.x, max_x.max(work_area.x));
    let panel_y = desired_y.clamp(work_area.y, max_y.max(work_area.y));

    set_window_position(&window, panel_x, panel_y);
}

fn position_panel_at_taskbar(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        log::error!("Panel window missing");
        return;
    };

    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        log::warn!("No monitor available for taskbar panel positioning");
        return;
    };

    let panel = panel_layout_for_window(&window);
    let work_area = work_area_layout(&monitor);
    let gap = 12.0;
    let panel_x = (work_area.x + work_area.width - panel.width - gap).max(work_area.x);
    let panel_y = (work_area.y + work_area.height - panel.height - gap).max(work_area.y);

    set_window_position(&window, panel_x, panel_y);
}
