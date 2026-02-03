use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::path::BaseDirectory;
use tauri::tray::{MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_nspanel::ManagerExt;
use tauri_plugin_store::StoreExt;

use crate::panel::position_panel_at_tray_icon;

const LOG_LEVEL_STORE_KEY: &str = "logLevel";

fn get_stored_log_level(app_handle: &AppHandle) -> log::LevelFilter {
    let store = match app_handle.store("settings.json") {
        Ok(s) => s,
        Err(_) => return log::LevelFilter::Error,
    };
    let value = store.get(LOG_LEVEL_STORE_KEY);
    let level_str = value.and_then(|v| v.as_str().map(|s| s.to_string()));
    match level_str.as_deref() {
        Some("error") => log::LevelFilter::Error,
        Some("warn") => log::LevelFilter::Warn,
        Some("info") => log::LevelFilter::Info,
        Some("debug") => log::LevelFilter::Debug,
        Some("trace") => log::LevelFilter::Trace,
        _ => log::LevelFilter::Error, // Default: least verbose
    }
}

fn set_stored_log_level(app_handle: &AppHandle, level: log::LevelFilter) {
    let level_str = match level {
        log::LevelFilter::Error => "error",
        log::LevelFilter::Warn => "warn",
        log::LevelFilter::Info => "info",
        log::LevelFilter::Debug => "debug",
        log::LevelFilter::Trace => "trace",
        log::LevelFilter::Off => "off",
    };
    if let Ok(store) = app_handle.store("settings.json") {
        store.set(LOG_LEVEL_STORE_KEY, serde_json::json!(level_str));
        let _ = store.save();
    }
    log::set_max_level(level);
    log::info!("Log level changed to {:?}", level);
}

fn update_log_level_menu_checks(app_handle: &AppHandle, level: log::LevelFilter) {
    let levels = [
        ("log_error", log::LevelFilter::Error),
        ("log_warn", log::LevelFilter::Warn),
        ("log_info", log::LevelFilter::Info),
        ("log_debug", log::LevelFilter::Debug),
        ("log_trace", log::LevelFilter::Trace),
    ];
    for (id, lvl) in levels {
        if let Some(item) = app_handle.menu().and_then(|m| m.get(id)) {
            if let Some(check) = item.as_check_menuitem() {
                let _ = check.set_checked(lvl == level);
            }
        }
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

fn show_panel(app_handle: &AppHandle) {
    if let Some(panel) = get_or_init_panel!(app_handle) {
        panel.show_and_make_key();
    }
}

pub fn create(app_handle: &AppHandle) -> tauri::Result<()> {
    let tray_icon_path = app_handle
        .path()
        .resolve("icons/tray-icon.png", BaseDirectory::Resource)?;
    let icon = Image::from_path(tray_icon_path)?;

    // Load persisted log level
    let current_level = get_stored_log_level(app_handle);
    log::set_max_level(current_level);

    let show_stats = MenuItem::with_id(app_handle, "show_stats", "Show Stats", true, None::<&str>)?;
    let go_to_settings = MenuItem::with_id(app_handle, "go_to_settings", "Go to Settings", true, None::<&str>)?;

    // Log level submenu
    let log_error = CheckMenuItem::with_id(app_handle, "log_error", "Error", true, current_level == log::LevelFilter::Error, None::<&str>)?;
    let log_warn = CheckMenuItem::with_id(app_handle, "log_warn", "Warn", true, current_level == log::LevelFilter::Warn, None::<&str>)?;
    let log_info = CheckMenuItem::with_id(app_handle, "log_info", "Info", true, current_level == log::LevelFilter::Info, None::<&str>)?;
    let log_debug = CheckMenuItem::with_id(app_handle, "log_debug", "Debug", true, current_level == log::LevelFilter::Debug, None::<&str>)?;
    let log_trace = CheckMenuItem::with_id(app_handle, "log_trace", "Trace", true, current_level == log::LevelFilter::Trace, None::<&str>)?;
    let log_level_submenu = Submenu::with_items(
        app_handle,
        "Debug Level",
        true,
        &[&log_error, &log_warn, &log_info, &log_debug, &log_trace],
    )?;

    let separator = PredefinedMenuItem::separator(app_handle)?;
    let about = MenuItem::with_id(app_handle, "about", "About OpenUsage", true, None::<&str>)?;
    let quit = MenuItem::with_id(app_handle, "quit", "Quit", true, None::<&str>)?;

    let menu = Menu::with_items(app_handle, &[&show_stats, &go_to_settings, &log_level_submenu, &separator, &about, &quit])?;

    TrayIconBuilder::with_id("tray")
        .icon(icon)
        .icon_as_template(true)
        .tooltip("OpenUsage")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app_handle, event| {
            log::debug!("tray menu: {}", event.id.as_ref());
            match event.id.as_ref() {
                "show_stats" => {
                    show_panel(app_handle);
                    let _ = app_handle.emit("tray:navigate", "home");
                }
                "go_to_settings" => {
                    show_panel(app_handle);
                    let _ = app_handle.emit("tray:navigate", "settings");
                }
                "about" => {
                    show_panel(app_handle);
                    let _ = app_handle.emit("tray:show-about", ());
                }
                "quit" => {
                    log::info!("quit requested via tray");
                    app_handle.exit(0);
                }
                "log_error" => {
                    set_stored_log_level(app_handle, log::LevelFilter::Error);
                    update_log_level_menu_checks(app_handle, log::LevelFilter::Error);
                }
                "log_warn" => {
                    set_stored_log_level(app_handle, log::LevelFilter::Warn);
                    update_log_level_menu_checks(app_handle, log::LevelFilter::Warn);
                }
                "log_info" => {
                    set_stored_log_level(app_handle, log::LevelFilter::Info);
                    update_log_level_menu_checks(app_handle, log::LevelFilter::Info);
                }
                "log_debug" => {
                    set_stored_log_level(app_handle, log::LevelFilter::Debug);
                    update_log_level_menu_checks(app_handle, log::LevelFilter::Debug);
                }
                "log_trace" => {
                    set_stored_log_level(app_handle, log::LevelFilter::Trace);
                    update_log_level_menu_checks(app_handle, log::LevelFilter::Trace);
                }
                _ => {}
            }
        })
        .on_tray_icon_event(|tray, event| {
            let app_handle = tray.app_handle();

            if let TrayIconEvent::Click {
                button_state, rect, ..
            } = event
            {
                if button_state == MouseButtonState::Up {
                    let Some(panel) = get_or_init_panel!(app_handle) else {
                        return;
                    };

                    if panel.is_visible() {
                        log::debug!("tray click: hiding panel");
                        panel.hide();
                        return;
                    }
                    log::debug!("tray click: showing panel");

                    // macOS quirk: must show window before positioning to another monitor
                    panel.show_and_make_key();
                    position_panel_at_tray_icon(app_handle, rect.position, rect.size);
                }
            }
        })
        .build(app_handle)?;

    Ok(())
}
