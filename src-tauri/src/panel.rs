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
            .can_join_all_spaces()
            .stationary()
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

    // Tray icon events on macOS report coordinates labeled as Physical, but they
    // live in a hybrid global space where each monitor region uses its own scale.
    // When monitors have different DPIs, regions can overlap in this space.
    //
    // We disambiguate by checking the icon's physical size: on a Retina (2x)
    // display the tray icon is reported as ~132x78 physical, while on a 1x display
    // it is ~66x30. This tells us the scale of the monitor the icon is on.

    let (icon_phys_x, icon_phys_y) = match &icon_position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    };
    let (icon_phys_w, icon_phys_h) = match &icon_size {
        Size::Physical(s) => (s.width as f64, s.height as f64),
        Size::Logical(s) => (s.width, s.height),
    };

    // Determine the icon's scale from its physical size.
    // A tray icon at 1x is ~66 wide; at 2x it's ~132. Use width > 100 as heuristic.
    let icon_scale = if icon_phys_w > 100.0 { 2.0 } else { 1.0 };

    log::error!(
        "position_panel: icon_phys=({:.0}, {:.0}), icon_phys_size=({:.0}, {:.0}), icon_scale={}",
        icon_phys_x, icon_phys_y, icon_phys_w, icon_phys_h, icon_scale
    );

    let monitors = window.available_monitors().expect("failed to get monitors");
    let mut found_monitor = None;

    for m in &monitors {
        let logical_pos = m.position();
        let phys_size = m.size();
        let scale = m.scale_factor();

        // Each monitor's region in the tray coordinate space:
        // origin = logical_pos * scale (its own scale), extent = physical size
        let phys_origin_x = logical_pos.x as f64 * scale;
        let phys_origin_y = logical_pos.y as f64 * scale;
        let phys_w = phys_size.width as f64;
        let phys_h = phys_size.height as f64;

        log::error!(
            "  monitor: {:?}, logical_pos=({}, {}), phys_origin=({:.0}, {:.0}), phys_size={:.0}x{:.0}, scale={}",
            m.name(), logical_pos.x, logical_pos.y, phys_origin_x, phys_origin_y, phys_w, phys_h, scale
        );

        let x_in = icon_phys_x >= phys_origin_x && icon_phys_x < phys_origin_x + phys_w;
        let y_in = icon_phys_y >= phys_origin_y && icon_phys_y < phys_origin_y + phys_h;

        if x_in && y_in {
            // When regions overlap, prefer the monitor whose scale matches the icon's
            if found_monitor.is_none() || (scale - icon_scale).abs() < 0.1 {
                found_monitor = Some((m.clone(), phys_origin_x, phys_origin_y));
            }
        }
    }

    let (monitor, phys_origin_x, phys_origin_y) = match found_monitor {
        Some(v) => v,
        None => {
            log::error!("No monitor found for icon at ({:.0}, {:.0}), using primary", icon_phys_x, icon_phys_y);
            match window.primary_monitor() {
                Ok(Some(m)) => (m, 0.0, 0.0),
                _ => return,
            }
        }
    };

    let target_scale = monitor.scale_factor();
    let mon_logical_x = monitor.position().x as f64;
    let mon_logical_y = monitor.position().y as f64;

    // Convert icon physical coords to logical:
    // offset within the monitor in physical pixels -> divide by target scale -> add logical origin
    let icon_logical_x = mon_logical_x + (icon_phys_x - phys_origin_x) / target_scale;
    let icon_logical_y = mon_logical_y + (icon_phys_y - phys_origin_y) / target_scale;
    let icon_logical_w = icon_phys_w / target_scale;
    let icon_logical_h = icon_phys_h / target_scale;

    // Panel width in logical points (fixed at 400pt as configured in tauri.conf.json)
    let panel_width = 400.0_f64;

    let icon_center_x = icon_logical_x + (icon_logical_w / 2.0);
    let panel_x = icon_center_x - (panel_width / 2.0);
    let nudge_up: f64 = 6.0;
    let panel_y = icon_logical_y + icon_logical_h - nudge_up;

    log::error!(
        "  target={:?}, scale={}, icon_logical=({:.1}, {:.1}), final=({:.1}, {:.1}), panel_w={:.0}",
        monitor.name(), target_scale, icon_logical_x, icon_logical_y, panel_x, panel_y, panel_width
    );

    let _ = window.set_position(tauri::LogicalPosition::new(panel_x, panel_y));
}
