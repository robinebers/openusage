#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(not(target_os = "macos"))]
pub use windows::*;

#[cfg(target_os = "macos")]
mod macos {
    use tauri::{AppHandle, Manager, Position, Size};
    use tauri_nspanel::{
        CollectionBehavior, ManagerExt, PanelLevel, StyleMask, WebviewWindowExt, tauri_panel,
    };

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

    pub(crate) use get_or_init_panel;

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

    pub fn show_panel(app_handle: &AppHandle) {
        if let Some(panel) = get_or_init_panel!(app_handle) {
            panel.show_and_make_key();
            if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                position_panel_from_tray(app_handle);
            }
        }
    }

    pub fn hide_panel(app_handle: &AppHandle) {
        if let Ok(panel) = app_handle.get_webview_panel("main") {
            panel.hide();
        }
    }

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
            if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                position_panel_from_tray(app_handle);
            }
        }
    }

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

        panel.set_has_shadow(false);
        panel.set_opaque(false);
        panel.set_level(PanelLevel::MainMenu.value() + 1);

        panel.set_collection_behavior(
            CollectionBehavior::new()
                .move_to_active_space()
                .full_screen_auxiliary()
                .value(),
        );

        panel.set_style_mask(StyleMask::empty().nonactivating_panel().value());

        let event_handler = OpenUsagePanelEventHandler::new();
        let handle = app_handle.clone();
        event_handler.window_did_resign_key(move |_notification| {
            if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                if let Ok(panel) = handle.get_webview_panel("main") {
                    panel.hide();
                }
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
}

#[cfg(not(target_os = "macos"))]
mod windows {
    use tauri::{AppHandle, Manager, Position, Size};

    macro_rules! get_window {
        ($app_handle:expr) => {
            $app_handle.get_webview_window("main")
        };
    }

    pub fn show_panel(app_handle: &AppHandle) {
        if let Some(window) = get_window!(app_handle) {
            let _ = window.show();
            let _ = window.set_focus();
            if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                position_panel_from_tray(app_handle);
            }
        }
    }

    pub fn hide_panel(app_handle: &AppHandle) {
        if let Some(window) = get_window!(app_handle) {
            let _ = window.hide();
        }
    }

    pub fn toggle_panel(app_handle: &AppHandle) {
        let Some(window) = get_window!(app_handle) else {
            return;
        };

        if window.is_visible().unwrap_or(false) {
            log::debug!("toggle_panel: hiding window");
            let _ = window.hide();
        } else {
            log::debug!("toggle_panel: showing window");
            let _ = window.show();
            let _ = window.set_focus();
            if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                position_panel_from_tray(app_handle);
            }
        }
    }

    pub fn init(app_handle: &tauri::AppHandle) -> tauri::Result<()> {
        if let Some(window) = get_window!(app_handle) {
            let _ = window.set_decorations(false);
            let _ = window.set_always_on_top(true);
            let _ = window.set_skip_taskbar(true);
            
            // Handle window blur to hide it
            let handle = app_handle.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::Focused(false) = event {
                    if !crate::IS_PINNED.load(std::sync::atomic::Ordering::SeqCst) {
                        if let Some(w) = get_window!(handle) {
                            let _ = w.hide();
                        }
                    }
                }
            });
        }
        Ok(())
    }

    fn position_panel_from_tray(app_handle: &AppHandle) {
        let Some(tray) = app_handle.tray_by_id("tray") else {
            return;
        };
        match tray.rect() {
            Ok(Some(rect)) => {
                position_panel_at_tray_icon(app_handle, rect.position, rect.size);
            }
            _ => {}
        }
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

        let outer_size = window.outer_size().unwrap_or(tauri::PhysicalSize::new(400, 500));
        let window_phys_w = outer_size.width as f64;
        let window_phys_h = outer_size.height as f64;

        let monitors = window.available_monitors().unwrap_or_default();
        let icon_center_x = icon_phys_x + (icon_phys_w / 2.0);
        let icon_center_y = icon_phys_y + (icon_phys_h / 2.0);

        let mut monitor_bounds = None;
        for monitor in monitors {
            let pos = monitor.position();
            let size = monitor.size();
            if icon_center_x >= pos.x as f64 && icon_center_x <= (pos.x + size.width as i32) as f64
                && icon_center_y >= pos.y as f64 && icon_center_y <= (pos.y + size.height as i32) as f64 {
                monitor_bounds = Some((*pos, *size));
                break;
            }
        }

        let gap = 10.0;
        let mut target_x = icon_center_x - (window_phys_w / 2.0);
        let mut target_y = icon_phys_y - window_phys_h - gap;

        if let Some((pos, size)) = monitor_bounds {
            let mon_right = pos.x as f64 + size.width as f64;
            if target_x + window_phys_w > mon_right {
                target_x = mon_right - window_phys_w;
            }
            if target_x < pos.x as f64 {
                target_x = pos.x as f64;
            }
            // Ensure we don't go below screen bounds either (e.g. if tray is at top somehow)
            if target_y < pos.y as f64 {
                // place below icon instead
                target_y = icon_phys_y + icon_phys_h + gap;
            }
        }

        let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition::new(
            target_x as i32,
            target_y as i32,
        )));
    }
}
