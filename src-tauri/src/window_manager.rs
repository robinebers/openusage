use tauri::{AppHandle, Manager, PhysicalPosition};

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

    // Calculate position: center horizontally above the tray icon
    let icon_center_x = icon_position.x + (icon_size.width as i32 / 2);
    let window_x = icon_center_x - (window_width / 2);
    let window_y = icon_position.y - window_height;

    // Clamp to monitor bounds
    let final_x = if let Some(ref monitor) = target_monitor {
        let monitor_x = monitor.position().x;
        let monitor_width = monitor.size().width as i32;
        window_x.clamp(monitor_x, monitor_x + monitor_width - window_width)
    } else {
        window_x.max(0)
    };

    let final_y = if let Some(ref monitor) = target_monitor {
        let monitor_y = monitor.position().y;
        monitor_y.max(window_y)
    } else {
        window_y.max(0)
    };

    // Convert to logical position
    let logical_pos =
        LogicalPosition::new(final_x as f64 / scale_factor, final_y as f64 / scale_factor);

    window.set_position(tauri::Position::Logical(logical_pos))?;

    Ok(())
}

/// macOS version delegates to existing panel implementation
#[cfg(target_os = "macos")]
pub fn position_window_at_tray(app_handle: &AppHandle, icon_position: Position, icon_size: Size) {
    crate::panel::position_panel_at_tray_icon(app_handle, icon_position, icon_size);
}
