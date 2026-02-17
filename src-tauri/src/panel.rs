use tauri::{AppHandle, Manager, Position, Size};
use tauri_nspanel::{tauri_panel, CollectionBehavior, ManagerExt, PanelLevel, StyleMask, WebviewWindowExt};

/// Macro to get existing panel or initialize it if needed.
/// Returns Option<Panel> - Some if panel is available, None on error.
macro_rules! get_or_init_panel {
    ($app_handle:expr) => {
        match $app_handle.get_webview_panel("main") {
            Ok(panel) => Some(panel),
            Err(_) => {
                if let Err(err) = crate::panel::init($app_handle) {
                    log::error!("Failed to init panel: {}", err);
                    None
                } else {
                    match $app_handle.get_webview_panel("main") {
                        Ok(panel) => Some(panel),
                        Err(err) => {
                            log::error!("Panel missing after init: {:?}", err);
                            None
                        }
                    }
                }
            }
        }
    };
}

// Export macro for use in other modules
pub(crate) use get_or_init_panel;

/// Show the panel (initializing if needed).
pub fn show_panel(app_handle: &AppHandle) {
    if let Some(panel) = get_or_init_panel!(app_handle) {
        panel.show_and_make_key();
    }
}

/// Toggle panel visibility. If visible, hide it. If hidden, show it.
/// Used by global shortcut handler.
pub fn toggle_panel(app_handle: &AppHandle) {
    let Some(panel) = get_or_init_panel!(app_handle) else {
        return;
    };

    if panel.is_visible() {
        log::debug!("toggle_panel: hiding panel");
        panel.hide();
    } else {
        log::debug!("toggle_panel: showing panel");
        panel.show_and_make_key();
    }
}

// Define our panel class and event handler together
tauri_panel! {
    panel!(OpenUsagePanel {
        config: {
            can_become_key_window: true,
            is_floating_panel: true
        }
    })

    panel_event!(OpenUsagePanelEventHandler {
        window_did_resign_key(notification: &NSNotification) -> ()
    })
}

pub fn init(app_handle: &tauri::AppHandle) -> tauri::Result<()> {
    if app_handle.get_webview_panel("main").is_ok() {
        return Ok(());
    }

    let window = app_handle.get_webview_window("main").unwrap();

    let panel = window.to_panel::<OpenUsagePanel>()?;

    // Disable native shadow - it causes gray border on transparent windows
    // Let CSS handle shadow via shadow-xl class
    panel.set_has_shadow(false);
    panel.set_opaque(false);

    // Configure panel behavior
    panel.set_level(PanelLevel::MainMenu.value() + 1);

    panel.set_collection_behavior(
        CollectionBehavior::new()
            .move_to_active_space()
            .full_screen_auxiliary()
            .value(),
    );

    panel.set_style_mask(StyleMask::empty().nonactivating_panel().value());

    // Set up event handler to hide panel when it loses focus
    let event_handler = OpenUsagePanelEventHandler::new();

    let handle = app_handle.clone();
    event_handler.window_did_resign_key(move |_notification| {
        if let Ok(panel) = handle.get_webview_panel("main") {
            panel.hide();
        }
    });

    panel.set_event_handler(Some(event_handler.as_ref()));

    Ok(())
}

pub fn position_panel_at_tray_icon(
    app_handle: &tauri::AppHandle,
    icon_position: Position,
    icon_size: Size,
) {
    let window = app_handle.get_webview_window("main").unwrap();

    // Extract icon position (tray events emit physical coords)
    let (icon_phys_x, icon_phys_y) = match &icon_position {
        Position::Physical(pos) => (pos.x, pos.y),
        Position::Logical(pos) => (pos.x as i32, pos.y as i32),
    };

    // Find the monitor containing this physical position
    // Note: monitor_from_point expects logical coords but tray events give physical,
    // so we manually check using physical coordinates
    let monitors = window.available_monitors().expect("failed to get monitors");
    let mut found_monitor = None;

    for m in monitors {
        let pos = m.position();
        let size = m.size();
        let x_in = icon_phys_x >= pos.x && icon_phys_x < pos.x + size.width as i32;
        let y_in = icon_phys_y >= pos.y && icon_phys_y < pos.y + size.height as i32;

        if x_in && y_in {
            found_monitor = Some(m);
            break;
        }
    }

    let monitor = found_monitor.expect("no monitor found containing tray icon position");

    let scale_factor = monitor.scale_factor();
    // Window size in physical pixels (outer_size is physical on macOS)
    let window_size = window.outer_size().unwrap();
    let window_width_phys = window_size.width as i32;

    // Convert icon position/size to physical coordinates
    let (icon_phys_x, icon_phys_y, icon_width_phys, icon_height_phys) = match (icon_position, icon_size) {
        (Position::Physical(pos), Size::Physical(size)) => (pos.x, pos.y, size.width as i32, size.height as i32),
        (Position::Logical(pos), Size::Logical(size)) => (
            (pos.x * scale_factor) as i32,
            (pos.y * scale_factor) as i32,
            (size.width * scale_factor) as i32,
            (size.height * scale_factor) as i32,
        ),
        (Position::Physical(pos), Size::Logical(size)) => (
            pos.x,
            pos.y,
            (size.width * scale_factor) as i32,
            (size.height * scale_factor) as i32,
        ),
        (Position::Logical(pos), Size::Physical(size)) => (
            (pos.x * scale_factor) as i32,
            (pos.y * scale_factor) as i32,
            size.width as i32,
            size.height as i32,
        ),
    };

    let icon_center_x_phys = icon_phys_x + (icon_width_phys / 2);
    let panel_x_phys = icon_center_x_phys - (window_width_phys / 2);
    let padding_phys = 0;
    // Nudge the panel slightly upward so it visually aligns tighter to the tray.
    // Use logical points (not physical px) so the offset looks consistent on Retina.
    let nudge_up_points: f64 = 6.0;
    let nudge_up_phys = (nudge_up_points * scale_factor).round() as i32;
    let panel_y_phys = icon_phys_y + icon_height_phys + padding_phys - nudge_up_phys;

    let final_pos = tauri::PhysicalPosition::new(panel_x_phys, panel_y_phys);

    let _ = window.set_position(final_pos);
}
