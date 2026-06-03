use std::sync::atomic::{AtomicBool, Ordering};

use tauri::{AppHandle, Manager, Position, Size};
use tauri_nspanel::{
    CollectionBehavior, ManagerExt, PanelLevel, StyleMask, WebviewWindowExt, tauri_panel,
};

/// True while the app runs as a Dock-only window (no tray icon). In this mode
/// the panel behaves like a normal window: it does not auto-hide on blur and is
/// centered instead of anchored under the (absent) tray icon.
static DOCK_MODE: AtomicBool = AtomicBool::new(false);

/// When in Dock mode, keep the window floating above other windows.
static ALWAYS_ON_TOP: AtomicBool = AtomicBool::new(false);

/// Tracks whether the Dock-only window has been positioned at least once this
/// session. We center it once per launch (the first time it shows), then leave
/// it wherever the user dragged it. Leaving Dock mode resets this.
static DOCK_POSITIONED: AtomicBool = AtomicBool::new(false);

pub fn set_dock_mode(enabled: bool) {
    DOCK_MODE.store(enabled, Ordering::SeqCst);
    if !enabled {
        DOCK_POSITIONED.store(false, Ordering::SeqCst);
    }
}

pub fn set_always_on_top(enabled: bool) {
    ALWAYS_ON_TOP.store(enabled, Ordering::SeqCst);
}

fn is_dock_mode() -> bool {
    DOCK_MODE.load(Ordering::SeqCst)
}

fn is_dock_positioned() -> bool {
    DOCK_POSITIONED.load(Ordering::SeqCst)
}

fn monitor_contains_physical_point(
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
    point_x: f64,
    point_y: f64,
) -> bool {
    point_x >= origin_x
        && point_x < origin_x + width
        && point_y >= origin_y
        && point_y < origin_y + height
}

unsafe fn set_panel_frame_top_left(panel: &tauri_nspanel::NSPanel, x: f64, y: f64) {
    let point = tauri_nspanel::NSPoint::new(x, y);
    let _: () = objc2::msg_send![panel, setFrameTopLeftPoint: point];
}

fn set_panel_top_left_immediately(
    window: &tauri::WebviewWindow,
    app_handle: &AppHandle,
    panel_x: f64,
    panel_y: f64,
    primary_logical_h: f64,
) {
    let Ok(panel_handle) = app_handle.get_webview_panel("main") else {
        return;
    };

    let target_x = panel_x;
    let target_y = primary_logical_h - panel_y;

    if objc2_foundation::MainThreadMarker::new().is_some() {
        unsafe {
            set_panel_frame_top_left(panel_handle.as_panel(), target_x, target_y);
        }
        return;
    }

    let (tx, rx) = std::sync::mpsc::channel();
    let panel_handle = panel_handle.clone();

    if let Err(error) = window.run_on_main_thread(move || {
        unsafe {
            set_panel_frame_top_left(panel_handle.as_panel(), target_x, target_y);
        }
        let _ = tx.send(());
    }) {
        log::warn!("Failed to position panel on main thread: {}", error);
        return;
    }

    if rx.recv().is_err() {
        log::warn!("Failed waiting for panel position on main thread");
    }
}

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

/// Retrieve the tray icon rect and position the panel beneath it.
/// No-ops gracefully if the tray icon or its rect is unavailable.
fn position_panel_from_tray(app_handle: &AppHandle) {
    let Some(tray) = app_handle.tray_by_id("tray") else {
        log::debug!("position_panel_from_tray: tray icon not found");
        return;
    };
    match tray.rect() {
        Ok(Some(rect)) => {
            position_panel_at_tray_icon(app_handle, rect.position, rect.size);
        }
        Ok(None) => {
            log::debug!("position_panel_from_tray: tray rect not available yet");
        }
        Err(e) => {
            log::warn!("position_panel_from_tray: failed to get tray rect: {}", e);
        }
    }
}

/// Show the panel (initializing if needed), positioned under the tray icon.
pub fn show_panel(app_handle: &AppHandle) {
    if let Some(panel) = get_or_init_panel!(app_handle) {
        panel.show_and_make_key();
        position_panel_from_tray(app_handle);
    }
}

/// Show the panel in Dock-only mode, where there is no tray icon to anchor to.
/// It is centered the first time it shows each launch, then left wherever the
/// user dragged it for the rest of the session.
pub fn show_panel_dock(app_handle: &AppHandle) {
    if let Some(panel) = get_or_init_panel!(app_handle) {
        panel.show_and_make_key();
        apply_panel_presentation(app_handle);
        if !is_dock_positioned() {
            position_panel_centered(app_handle);
        }
    }
}

/// Set the panel window level for the current mode. Menu-bar mode floats above
/// everything as a dropdown. Dock mode uses a normal window level, unless
/// "always on top" is enabled, in which case it floats above other windows.
pub fn apply_panel_presentation(app_handle: &AppHandle) {
    let Ok(panel) = app_handle.get_webview_panel("main") else {
        return;
    };
    let level = if is_dock_mode() {
        if ALWAYS_ON_TOP.load(Ordering::SeqCst) {
            PanelLevel::Floating.value()
        } else {
            PanelLevel::Normal.value()
        }
    } else {
        PanelLevel::MainMenu.value() + 1
    };
    panel.set_level(level);
}

/// Center the window on the primary monitor. Dock mode places the window here
/// on launch (and when first switching to Dock mode); the user can drag it
/// afterwards. Marks the window as positioned for the session.
pub fn position_panel_centered(app_handle: &AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        return;
    };

    let monitor = match window.primary_monitor() {
        Ok(Some(monitor)) => monitor,
        _ => return,
    };

    let scale = monitor.scale_factor();
    let mon_logical_x = monitor.position().x as f64 / scale;
    let mon_logical_y = monitor.position().y as f64 / scale;
    let mon_logical_w = monitor.size().width as f64 / scale;
    let mon_logical_h = monitor.size().height as f64 / scale;

    let (panel_w, panel_h) = match (window.outer_size(), window.scale_factor()) {
        (Ok(size), Ok(win_scale)) => (
            size.width as f64 / win_scale,
            size.height as f64 / win_scale,
        ),
        _ => (400.0, 500.0),
    };

    let panel_x = mon_logical_x + (mon_logical_w - panel_w) / 2.0;
    let panel_y = mon_logical_y + (mon_logical_h - panel_h) / 2.0;

    set_panel_top_left_immediately(&window, app_handle, panel_x, panel_y, mon_logical_h);
    DOCK_POSITIONED.store(true, Ordering::SeqCst);
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
        position_panel_from_tray(app_handle);
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
        // In Dock-only mode the panel is a normal, persistent window, so it
        // must stay open when it loses focus instead of auto-hiding.
        if is_dock_mode() {
            return;
        }
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

    let (icon_phys_x, icon_phys_y) = match &icon_position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    };
    let (icon_phys_w, icon_phys_h) = match &icon_size {
        Size::Physical(s) => (s.width as f64, s.height as f64),
        Size::Logical(s) => (s.width, s.height),
    };

    let monitors = window.available_monitors().expect("failed to get monitors");
    let primary_logical_h = window
        .primary_monitor()
        .ok()
        .flatten()
        .map(|m| m.size().height as f64 / m.scale_factor())
        .unwrap_or(0.0);

    let icon_center_x = icon_phys_x + (icon_phys_w / 2.0);
    let icon_center_y = icon_phys_y + (icon_phys_h / 2.0);

    let found_monitor = monitors.iter().find(|monitor| {
        let origin = monitor.position();
        let size = monitor.size();
        monitor_contains_physical_point(
            origin.x as f64,
            origin.y as f64,
            size.width as f64,
            size.height as f64,
            icon_center_x,
            icon_center_y,
        )
    });

    let monitor = match found_monitor {
        Some(m) => m.clone(),
        None => {
            log::warn!(
                "No monitor found for tray rect center at ({:.0}, {:.0}), using primary",
                icon_center_x,
                icon_center_y
            );
            match window.primary_monitor() {
                Ok(Some(m)) => m,
                _ => return,
            }
        }
    };

    let target_scale = monitor.scale_factor();
    let mon_phys_x = monitor.position().x as f64;
    let mon_phys_y = monitor.position().y as f64;
    let mon_logical_x = mon_phys_x / target_scale;
    let mon_logical_y = mon_phys_y / target_scale;

    let icon_logical_x = mon_logical_x + (icon_phys_x - mon_phys_x) / target_scale;
    let icon_logical_y = mon_logical_y + (icon_phys_y - mon_phys_y) / target_scale;
    let icon_logical_w = icon_phys_w / target_scale;
    let icon_logical_h = icon_phys_h / target_scale;

    // Read panel width from the window, converted to logical points.
    // outer_size() returns physical pixels at the window's current scale factor.
    // If the window isn't available yet, parse the configured width from tauri.conf.json
    // (embedded at compile time) so it stays in sync automatically.
    let panel_width = match (window.outer_size(), window.scale_factor()) {
        (Ok(s), Ok(win_scale)) => s.width as f64 / win_scale,
        _ => {
            let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
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

    set_panel_top_left_immediately(&window, app_handle, panel_x, panel_y, primary_logical_h);
}
