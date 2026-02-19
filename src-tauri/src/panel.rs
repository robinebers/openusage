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

    // Tray icon events on macOS report coordinates in a hybrid physical space where
    // each monitor region uses its own scale (logical_pos × scale = physical origin).
    // On mixed-DPI setups this creates overlapping regions, making it impossible to
    // reliably determine the correct monitor from tray coordinates alone.
    //
    // Instead, we use NSEvent::mouseLocation() which returns the cursor position in
    // macOS's unified logical (point) coordinate space — always unambiguous regardless
    // of how many monitors or scale factors are involved. We find which monitor
    // contains the cursor, then convert the tray icon's physical coordinates to
    // logical coordinates within that monitor.

    let (icon_phys_x, icon_phys_y) = match &icon_position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    };
    let (icon_phys_w, icon_phys_h) = match &icon_size {
        Size::Physical(s) => (s.width as f64, s.height as f64),
        Size::Logical(s) => (s.width, s.height),
    };

    // Get the cursor's logical position via NSEvent — this is in macOS's flipped
    // coordinate system (origin at bottom-left of primary screen).
    let mouse_logical = objc2_app_kit::NSEvent::mouseLocation();

    // Convert from macOS bottom-left origin to top-left origin used by Tauri.
    // Primary screen height (in points) defines the flip axis.
    let monitors = window.available_monitors().expect("failed to get monitors");
    let primary_logical_h = window
        .primary_monitor()
        .ok()
        .flatten()
        .map(|m| m.size().height as f64 / m.scale_factor())
        .unwrap_or(0.0);

    let mouse_x = mouse_logical.x;
    let mouse_y = primary_logical_h - mouse_logical.y;

    // Find the monitor containing the cursor in logical space (no ambiguity).
    let mut found_monitor = None;
    for m in &monitors {
        let pos = m.position();
        let scale = m.scale_factor();
        let logical_w = m.size().width as f64 / scale;
        let logical_h = m.size().height as f64 / scale;

        let logical_x = pos.x as f64 / scale;
        let logical_y = pos.y as f64 / scale;
        let x_in = mouse_x >= logical_x && mouse_x < logical_x + logical_w;
        let y_in = mouse_y >= logical_y && mouse_y < logical_y + logical_h;

        if x_in && y_in {
            found_monitor = Some(m.clone());
            break;
        }
    }

    let monitor = match found_monitor {
        Some(m) => m,
        None => {
            log::warn!(
                "No monitor found for cursor at ({:.0}, {:.0}), using primary",
                mouse_x, mouse_y
            );
            match window.primary_monitor() {
                Ok(Some(m)) => m,
                _ => return,
            }
        }
    };

    let target_scale = monitor.scale_factor();
    let mon_logical_x = monitor.position().x as f64;
    let mon_logical_y = monitor.position().y as f64;

    // Convert tray icon physical coords to logical within the identified monitor.
    // Physical origin of this monitor in the hybrid tray coordinate space:
    let phys_origin_x = mon_logical_x * target_scale;
    let phys_origin_y = mon_logical_y * target_scale;

    let icon_logical_x = mon_logical_x + (icon_phys_x - phys_origin_x) / target_scale;
    let icon_logical_y = mon_logical_y + (icon_phys_y - phys_origin_y) / target_scale;
    let icon_logical_w = icon_phys_w / target_scale;
    let icon_logical_h = icon_phys_h / target_scale;

    // Read panel width from the window, converted to logical points.
    // outer_size() returns physical pixels at the window's current scale factor.
    // If the window isn't available yet, parse the configured width from tauri.conf.json
    // (embedded at compile time) so it stays in sync automatically.
    let panel_width = match (window.outer_size(), window.scale_factor()) {
        (Ok(s), Ok(win_scale)) => s.width as f64 / win_scale,
        _ => {
            let conf: serde_json::Value =
                serde_json::from_str(include_str!("../tauri.conf.json"))
                    .expect("tauri.conf.json must be valid JSON");
            conf["app"]["windows"][0]["width"]
                .as_f64()
                .expect("width must be set in tauri.conf.json")
        }
    };

    let icon_center_x = icon_logical_x + (icon_logical_w / 2.0);
    let panel_x = icon_center_x - (panel_width / 2.0);
    let nudge_up: f64 = 6.0;
    let panel_y = icon_logical_y + icon_logical_h - nudge_up;

    let _ = window.set_position(tauri::LogicalPosition::new(panel_x, panel_y));
}
