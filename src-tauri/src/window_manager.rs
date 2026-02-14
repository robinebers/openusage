use tauri::{AppHandle, Emitter, Manager, PhysicalPosition};

#[cfg(target_os = "macos")]
use tauri::{Position, Size};

/// Platform-specific window manager
pub struct WindowManager;

impl WindowManager {
    /// Initialize the window for the current platform
    pub fn init(app_handle: &AppHandle) -> tauri::Result<()> {
        #[cfg(target_os = "macos")]
        {
            crate::panel::init(app_handle)?;
        }

        #[cfg(target_os = "windows")]
        {
            setup_windows_window(app_handle)?;
        }

        Ok(())
    }

    /// Show the window
    pub fn show(app_handle: &AppHandle) -> tauri::Result<()> {
        #[cfg(target_os = "macos")]
        {
            if let Ok(panel) = app_handle.get_webview_panel("main") {
                panel.show_and_make_key();
            } else {
                crate::panel::init(app_handle)?;
                if let Ok(panel) = app_handle.get_webview_panel("main") {
                    panel.show_and_make_key();
                }
            }
        }

        #[cfg(not(target_os = "macos"))]
        {
            if let Some(window) = app_handle.get_webview_window("main") {
                window.show()?;
                window.set_focus()?;
            }
        }

        Ok(())
    }

    /// Hide the window
    pub fn hide(app_handle: &AppHandle) -> tauri::Result<()> {
        #[cfg(target_os = "macos")]
        {
            if let Ok(panel) = app_handle.get_webview_panel("main") {
                panel.hide();
            }
        }

        #[cfg(not(target_os = "macos"))]
        {
            if let Some(window) = app_handle.get_webview_window("main") {
                window.hide()?;
            }
        }

        Ok(())
    }
}

/// Set up Windows-specific window styles for transparency
#[cfg(target_os = "windows")]
pub fn setup_windows_window(app_handle: &AppHandle) -> tauri::Result<()> {
    use tauri::Manager;

    if let Some(window) = app_handle.get_webview_window("main") {
        // Disable WebView2 hardware acceleration to fix transparency issues
        let _ =
            window.eval("document.documentElement.style.setProperty('background', 'transparent')");

        // Ensure window has no background
        let _ = window.eval(
            "
            if (document.body) {
                document.body.style.background = 'transparent';
                document.body.style.margin = '0';
                document.body.style.padding = '0';
            }
        ",
        );
    }

    Ok(())
}

/// Taskbar position enum - available on all platforms for AppState compatibility
#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskbarPosition {
    Top,
    Bottom,
    Left,
    Right,
}

/// Position the window at the tray icon location
#[cfg(target_os = "windows")]
pub fn position_window_at_tray(
    app_handle: &AppHandle,
    icon_position: PhysicalPosition<i32>,
    icon_size: tauri::PhysicalSize<u32>,
) -> tauri::Result<()> {
    use tauri::LogicalPosition;

    let window = app_handle
        .get_webview_window("main")
        .ok_or(tauri::Error::WindowNotFound)?;

    // Get window size
    let window_size = window.outer_size()?;
    let window_width = window_size.width as i32;
    let window_height = window_size.height as i32;

    // Calculate monitor and scale factor
    let monitors = window.available_monitors()?;
    let mut target_monitor = None;

    for monitor in monitors {
        let pos = monitor.position();
        let size = monitor.size();
        let x_in = icon_position.x >= pos.x && icon_position.x < pos.x + size.width as i32;
        let y_in = icon_position.y >= pos.y && icon_position.y < pos.y + size.height as i32;

        if x_in && y_in {
            target_monitor = Some(monitor);
            break;
        }
    }

    let scale_factor = target_monitor
        .as_ref()
        .map(|m| m.scale_factor())
        .unwrap_or(1.0);

    let monitor = target_monitor.as_ref();
    let monitor_rect = monitor.map(|m| {
        let pos = m.position();
        let size = m.size();
        (pos.x, pos.y, size.width as i32, size.height as i32)
    });
    let work_rect = monitor.map(|m| {
        let area = m.work_area();
        let pos = area.position;
        let size = area.size;
        (pos.x, pos.y, size.width as i32, size.height as i32)
    });

    // Detect taskbar position based on icon location
    let taskbar_position = detect_taskbar_position(icon_position, icon_size, monitor_rect);

    // Calculate window position based on taskbar location
    let (window_x, window_y) = calculate_window_position(
        icon_position,
        icon_size,
        window_width,
        window_height,
        taskbar_position,
        monitor_rect,
        work_rect,
    );

    // Convert to logical position
    let logical_pos = LogicalPosition::new(
        window_x as f64 / scale_factor,
        window_y as f64 / scale_factor,
    );

    window.set_position(tauri::Position::Logical(logical_pos))?;

    // Calculate arrow offset: where the icon center is relative to window edge
    // Top/Bottom -> X offset, Left/Right -> Y offset
    let icon_center_x = icon_position.x + (icon_size.width as i32 / 2);
    let icon_center_y = icon_position.y + (icon_size.height as i32 / 2);
    let arrow_offset_physical = match taskbar_position {
        TaskbarPosition::Left | TaskbarPosition::Right => icon_center_y - window_y,
        TaskbarPosition::Top | TaskbarPosition::Bottom => icon_center_x - window_x,
    };
    let arrow_offset_logical = (arrow_offset_physical as f64 / scale_factor) as i32;

    // Store taskbar position + arrow offset for frontend fallback
    if let Some(state) = app_handle.try_state::<std::sync::Mutex<crate::AppState>>() {
        if let Ok(mut app_state) = state.lock() {
            app_state.last_taskbar_position = Some(taskbar_position);
            app_state.last_arrow_offset = Some(arrow_offset_logical);
        }
    }

    println!(
        "DEBUG: Positioning window. Arrow Offset: {}, Taskbar: {:?}",
        arrow_offset_logical, taskbar_position
    );

    // Emit event to frontend with arrow position info
    if let Err(e) = window.emit(
        "window:positioned",
        serde_json::json!({
            "arrowOffset": arrow_offset_logical,
            "taskbarPosition": taskbar_position,
        }),
    ) {
        println!("ERROR: Failed to emit window:positioned event: {}", e);
    }

    Ok(())
}

/// Detect taskbar position based on tray icon location
#[cfg(target_os = "windows")]
fn detect_taskbar_position(
    icon_position: PhysicalPosition<i32>,
    icon_size: tauri::PhysicalSize<u32>,
    monitor_rect: Option<(i32, i32, i32, i32)>,
) -> TaskbarPosition {
    let Some((monitor_x, monitor_y, monitor_width, monitor_height)) = monitor_rect else {
        return TaskbarPosition::Bottom; // Default to bottom
    };

    let icon_center_x = icon_position.x + (icon_size.width as i32 / 2);
    let icon_center_y = icon_position.y + (icon_size.height as i32 / 2);

    // Calculate distance to each edge
    let dist_to_left = icon_center_x - monitor_x;
    let dist_to_right = (monitor_x + monitor_width) - icon_center_x;
    let dist_to_top = icon_center_y - monitor_y;
    let dist_to_bottom = (monitor_y + monitor_height) - icon_center_y;

    // Find the closest edge
    let min_dist = dist_to_left
        .min(dist_to_right)
        .min(dist_to_top)
        .min(dist_to_bottom);

    if min_dist == dist_to_top {
        TaskbarPosition::Top
    } else if min_dist == dist_to_bottom {
        TaskbarPosition::Bottom
    } else if min_dist == dist_to_left {
        TaskbarPosition::Left
    } else {
        TaskbarPosition::Right
    }
}

/// Calculate window position based on taskbar position
#[cfg(target_os = "windows")]
fn calculate_window_position(
    icon_position: PhysicalPosition<i32>,
    icon_size: tauri::PhysicalSize<u32>,
    window_width: i32,
    window_height: i32,
    taskbar_position: TaskbarPosition,
    monitor_rect: Option<(i32, i32, i32, i32)>,
    work_rect: Option<(i32, i32, i32, i32)>,
) -> (i32, i32) {
    let Some((monitor_x, monitor_y, monitor_width, monitor_height)) = monitor_rect else {
        // Fallback: center above icon
        let x = icon_position.x + (icon_size.width as i32 / 2) - (window_width / 2);
        let y = icon_position.y - window_height;
        return (x.max(0), y.max(0));
    };

    let (bounds_x, bounds_y, bounds_width, bounds_height) =
        work_rect.unwrap_or((monitor_x, monitor_y, monitor_width, monitor_height));

    let padding = 8; // Gap between window and taskbar

    let (x, y) = match taskbar_position {
        TaskbarPosition::Bottom => {
            // Window appears above the taskbar
            let icon_center_x = icon_position.x + (icon_size.width as i32 / 2);
            let window_x = icon_center_x - (window_width / 2);
            let window_y = icon_position.y - window_height - padding;
            (window_x, window_y)
        }
        TaskbarPosition::Top => {
            // Window appears below the taskbar
            let icon_center_x = icon_position.x + (icon_size.width as i32 / 2);
            let window_x = icon_center_x - (window_width / 2);
            let window_y = icon_position.y + icon_size.height as i32 + padding;
            (window_x, window_y)
        }
        TaskbarPosition::Left => {
            // Window appears to the right of the taskbar
            let window_x = bounds_x + padding;
            let icon_center_y = icon_position.y + (icon_size.height as i32 / 2);
            let window_y = icon_center_y - (window_height / 2);
            (window_x, window_y)
        }
        TaskbarPosition::Right => {
            // Window appears to the left of the taskbar
            let window_x = bounds_x + bounds_width - window_width - padding;
            let icon_center_y = icon_position.y + (icon_size.height as i32 / 2);
            let window_y = icon_center_y - (window_height / 2);
            (window_x, window_y)
        }
    };

    // Clamp to work area bounds
    let max_x = bounds_x + bounds_width - window_width;
    let max_y = bounds_y + bounds_height - window_height;

    let final_x = if max_x < bounds_x {
        bounds_x
    } else {
        x.clamp(bounds_x, max_x)
    };

    let final_y = if max_y < bounds_y {
        bounds_y
    } else {
        y.clamp(bounds_y, max_y)
    };

    (final_x, final_y)
}

/// macOS version delegates to existing panel implementation
#[cfg(target_os = "macos")]
pub fn position_window_at_tray(app_handle: &AppHandle, icon_position: Position, icon_size: Size) {
    crate::panel::position_panel_at_tray_icon(app_handle, icon_position, icon_size);
}

/// Linux version positions the window near the tray icon
#[cfg(target_os = "linux")]
pub fn position_window_at_tray(
    app_handle: &AppHandle,
    icon_position: PhysicalPosition<i32>,
    _icon_size: tauri::PhysicalSize<u32>,
) -> tauri::Result<()> {
    let window = app_handle
        .get_webview_window("main")
        .ok_or(tauri::Error::WindowNotFound)?;
    window.set_position(tauri::Position::Physical(icon_position))?;
    Ok(())
}
