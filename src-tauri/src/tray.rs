use std::collections::HashMap;
use std::sync::Mutex;

use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::path::BaseDirectory;
use tauri::tray::{MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_store::StoreExt;

use crate::plugin_engine::runtime::{MetricLine, PluginOutput};
use crate::window_manager::{position_window_at_tray, WindowManager};
use crate::AppState;

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
        _ => log::LevelFilter::Error,
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
    log::info!("Log level changing to {:?}", level);
    if let Ok(store) = app_handle.store("settings.json") {
        store.set(LOG_LEVEL_STORE_KEY, serde_json::json!(level_str));
        let _ = store.save();
    }
    log::set_max_level(level);
}

/// Build a dynamic tray menu with plugin data
fn build_tray_menu(
    app_handle: &AppHandle,
    probe_results: &HashMap<String, PluginOutput>,
) -> tauri::Result<Menu<tauri::Wry>> {
    let state = app_handle.state::<Mutex<AppState>>();
    let plugins = if let Ok(app_state) = state.lock() {
        app_state.plugins.clone()
    } else {
        vec![]
    };

    // Build static menu items first
    let show_stats = MenuItem::with_id(app_handle, "show_stats", "Show Stats", true, None::<&str>)?;
    let go_to_settings = MenuItem::with_id(
        app_handle,
        "go_to_settings",
        "Go to Settings",
        true,
        None::<&str>,
    )?;

    // Log level submenu
    let current_level = get_stored_log_level(app_handle);
    let log_error = CheckMenuItem::with_id(
        app_handle,
        "log_error",
        "Error",
        true,
        current_level == log::LevelFilter::Error,
        None::<&str>,
    )?;
    let log_warn = CheckMenuItem::with_id(
        app_handle,
        "log_warn",
        "Warn",
        true,
        current_level == log::LevelFilter::Warn,
        None::<&str>,
    )?;
    let log_info = CheckMenuItem::with_id(
        app_handle,
        "log_info",
        "Info",
        true,
        current_level == log::LevelFilter::Info,
        None::<&str>,
    )?;
    let log_debug = CheckMenuItem::with_id(
        app_handle,
        "log_debug",
        "Debug",
        true,
        current_level == log::LevelFilter::Debug,
        None::<&str>,
    )?;
    let log_trace = CheckMenuItem::with_id(
        app_handle,
        "log_trace",
        "Trace",
        true,
        current_level == log::LevelFilter::Trace,
        None::<&str>,
    )?;

    let log_level_submenu = Submenu::with_items(
        app_handle,
        "Debug Level",
        true,
        &[&log_error, &log_warn, &log_info, &log_debug, &log_trace],
    )?;

    let separator = PredefinedMenuItem::separator(app_handle)?;
    let separator2 = PredefinedMenuItem::separator(app_handle)?;

    let about = MenuItem::with_id(app_handle, "about", "About OpenUsage", true, None::<&str>)?;
    let quit = MenuItem::with_id(app_handle, "quit", "Quit", true, None::<&str>)?;

    // Build provider items (max 5)
    let mut provider_items: Vec<MenuItem<tauri::Wry>> = vec![];
    for plugin in plugins.iter().take(5) {
        let plugin_id = &plugin.manifest.id;
        let plugin_name = &plugin.manifest.name;

        if let Some(output) = probe_results.get(plugin_id) {
            // Find primary metric to display
            let primary_line = output.lines.iter().find(|line| {
                matches!(line, MetricLine::Progress { label, .. } if {
                    plugin.manifest.lines.iter().any(|manifest_line| {
                        manifest_line.line_type == "progress"
                            && manifest_line.label == *label
                            && manifest_line.primary_order.is_some()
                    })
                })
            });

            let display_text = if let Some(MetricLine::Progress { used, limit, .. }) = primary_line
            {
                let percentage = if *limit > 0.0 {
                    ((*used / *limit) * 100.0) as i32
                } else {
                    0
                };
                format!("{}: {}%", plugin_name, percentage)
            } else if let Some(first_line) = output.lines.first() {
                match first_line {
                    MetricLine::Progress { used, limit, .. } => {
                        let percentage = if *limit > 0.0 {
                            ((*used / *limit) * 100.0) as i32
                        } else {
                            0
                        };
                        format!("{}: {}%", plugin_name, percentage)
                    }
                    MetricLine::Text { value, .. } => {
                        format!("{}: {}", plugin_name, value)
                    }
                    MetricLine::Badge { text, .. } => {
                        format!("{}: {}", plugin_name, text)
                    }
                }
            } else {
                plugin_name.clone()
            };

            let item = MenuItem::with_id(
                app_handle,
                format!("provider_{}", plugin_id),
                display_text,
                true,
                None::<&str>,
            )?;
            provider_items.push(item);
        }
    }

    // Build final menu based on how many provider items we have
    // Use references to avoid move issues
    let menu = match provider_items.len() {
        0 => Menu::with_items(
            app_handle,
            &[
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
        1 => Menu::with_items(
            app_handle,
            &[
                &provider_items[0],
                &separator2,
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
        2 => Menu::with_items(
            app_handle,
            &[
                &provider_items[0],
                &provider_items[1],
                &separator2,
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
        3 => Menu::with_items(
            app_handle,
            &[
                &provider_items[0],
                &provider_items[1],
                &provider_items[2],
                &separator2,
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
        4 => Menu::with_items(
            app_handle,
            &[
                &provider_items[0],
                &provider_items[1],
                &provider_items[2],
                &provider_items[3],
                &separator2,
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
        _ => Menu::with_items(
            app_handle,
            &[
                &provider_items[0],
                &provider_items[1],
                &provider_items[2],
                &provider_items[3],
                &provider_items[4],
                &separator2,
                &show_stats,
                &go_to_settings,
                &log_level_submenu,
                &separator,
                &about,
                &quit,
            ],
        )?,
    };

    Ok(menu)
}

/// Update the tray menu with latest probe results
pub fn update_tray_menu(app_handle: &AppHandle) -> tauri::Result<()> {
    let probe_results = {
        let state = app_handle.state::<Mutex<AppState>>();
        if let Ok(app_state) = state.lock() {
            app_state.latest_probe_results.clone()
        } else {
            HashMap::new()
        }
    };

    let new_menu = build_tray_menu(app_handle, &probe_results)?;

    // Get the tray and update its menu
    if let Some(tray) = app_handle.tray_by_id("tray") {
        tray.set_menu(Some(new_menu))?;
    }

    Ok(())
}

pub fn create(app_handle: &AppHandle) -> tauri::Result<()> {
    // Platform-specific tray icon - Windows uses larger PNG, macOS uses template PNG
    #[cfg(target_os = "windows")]
    let icon_candidates = ["icons/64x64.png", "icons/icon.png"];

    #[cfg(not(target_os = "windows"))]
    let icon_candidates = ["icons/tray-icon.png", "icons/icon.png"];

    // Try multiple icon locations (for dev mode compatibility)
    let mut icon = None;
    let mut last_error = None;

    // First try Resource directory (works in release builds)
    for icon_path_str in &icon_candidates {
        match app_handle
            .path()
            .resolve(icon_path_str, BaseDirectory::Resource)
        {
            Ok(path) => {
                log::info!("Trying tray icon (Resource): {:?}", path);
                match Image::from_path(&path) {
                    Ok(img) => {
                        log::info!("Tray icon loaded successfully from: {:?}", path);
                        icon = Some(img);
                        break;
                    }
                    Err(e) => {
                        log::warn!("Failed to load icon from {:?}: {}", path, e);
                        last_error = Some(e);
                    }
                }
            }
            Err(e) => {
                log::warn!("Failed to resolve icon path '{}': {}", icon_path_str, e);
                last_error = Some(e);
            }
        }
    }

    // If Resource didn't work, try App directory (dev mode fallback)
    if icon.is_none() {
        for icon_path_str in &icon_candidates {
            match app_handle
                .path()
                .resolve(icon_path_str, BaseDirectory::AppLocalData)
            {
                Ok(path) => {
                    log::info!("Trying tray icon (AppLocalData): {:?}", path);
                    match Image::from_path(&path) {
                        Ok(img) => {
                            log::info!("Tray icon loaded successfully from: {:?}", path);
                            icon = Some(img);
                            break;
                        }
                        Err(e) => {
                            log::warn!("Failed to load icon from {:?}: {}", path, e);
                            last_error = Some(e);
                        }
                    }
                }
                Err(e) => {
                    log::warn!(
                        "Failed to resolve AppLocalData icon path '{}': {}",
                        icon_path_str,
                        e
                    );
                    last_error = Some(e);
                }
            }
        }
    }

    let icon = match icon {
        Some(img) => img,
        None => {
            log::error!("Could not load any tray icon. Last error: {:?}", last_error);
            return Err(last_error.unwrap_or(tauri::Error::UnknownPath));
        }
    };

    // Load persisted log level
    let current_level = get_stored_log_level(app_handle);
    log::set_max_level(current_level);

    // Build initial menu (empty probe results)
    let menu = build_tray_menu(app_handle, &HashMap::new())?;

    // Platform-specific tray icon builder
    #[cfg(target_os = "windows")]
    let builder = TrayIconBuilder::with_id("tray")
        .icon(icon)
        .tooltip("OpenUsage")
        .menu(&menu)
        .show_menu_on_left_click(false);

    #[cfg(not(target_os = "windows"))]
    let builder = TrayIconBuilder::with_id("tray")
        .icon(icon)
        .icon_as_template(true)
        .tooltip("OpenUsage")
        .menu(&menu)
        .show_menu_on_left_click(false);

    builder
        .on_menu_event(move |app_handle, event| {
            log::debug!("tray menu: {}", event.id.as_ref());
            match event.id.as_ref() {
                id if id.starts_with("provider_") => {
                    // Provider item clicked - show stats and navigate to provider
                    let plugin_id = id.strip_prefix("provider_").unwrap_or(id);
                    let _ = WindowManager::show(app_handle);
                    let _ = app_handle.emit("tray:navigate", "home");
                    let _ = app_handle.emit("tray:select-provider", plugin_id);
                }
                "show_stats" => {
                    let _ = WindowManager::show(app_handle);
                    let _ = app_handle.emit("tray:navigate", "home");
                }
                "go_to_settings" => {
                    let _ = WindowManager::show(app_handle);
                    let _ = app_handle.emit("tray:navigate", "settings");
                }
                "about" => {
                    let _ = WindowManager::show(app_handle);
                    let _ = app_handle.emit("tray:show-about", ());
                }
                "quit" => {
                    log::info!("quit requested via tray");
                    app_handle.exit(0);
                }
                "log_error" | "log_warn" | "log_info" | "log_debug" | "log_trace" => {
                    let selected_level = match event.id.as_ref() {
                        "log_error" => log::LevelFilter::Error,
                        "log_warn" => log::LevelFilter::Warn,
                        "log_info" => log::LevelFilter::Info,
                        "log_debug" => log::LevelFilter::Debug,
                        "log_trace" => log::LevelFilter::Trace,
                        _ => unreachable!(),
                    };
                    set_stored_log_level(app_handle, selected_level);
                    // Update the menu to reflect new log level
                    let _ = update_tray_menu(app_handle);
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
                    #[cfg(target_os = "macos")]
                    {
                        // macOS: Use panel behavior
                        use tauri_nspanel::ManagerExt;

                        let panel = match app_handle.get_webview_panel("main") {
                            Ok(p) => Some(p),
                            Err(_) => {
                                if let Err(err) = crate::panel::init(&app_handle) {
                                    log::error!("Failed to init panel: {}", err);
                                    None
                                } else {
                                    app_handle.get_webview_panel("main").ok()
                                }
                            }
                        };

                        if let Some(panel) = panel {
                            if panel.is_visible() {
                                log::debug!("tray click: hiding panel");
                                panel.hide();
                                return;
                            }
                            log::debug!("tray click: showing panel");
                            panel.show_and_make_key();
                            position_window_at_tray(app_handle, rect.position, rect.size);
                        }
                    }

                    #[cfg(target_os = "windows")]
                    {
                        // Windows: Use regular window
                        let window = app_handle.get_webview_window("main");

                        if let Some(window) = window {
                            if window.is_visible().unwrap_or(false) {
                                log::debug!("tray click: hiding window");
                                let _ = window.hide();
                                return;
                            }

                            log::debug!("tray click: showing window");

                            // Position window near tray icon
                            if let (tauri::Position::Physical(pos), tauri::Size::Physical(size)) =
                                (rect.position, rect.size)
                            {
                                let _ = position_window_at_tray(&app_handle, pos, size);
                            }

                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }

                    #[cfg(target_os = "linux")]
                    {
                        // Linux: Use regular window
                        let window = app_handle.get_webview_window("main");

                        if let Some(window) = window {
                            if window.is_visible().unwrap_or(false) {
                                log::debug!("tray click: hiding window");
                                let _ = window.hide();
                                return;
                            }

                            log::debug!("tray click: showing window");

                            // Position window near tray icon
                            if let (tauri::Position::Physical(pos), tauri::Size::Physical(size)) =
                                (rect.position, rect.size)
                            {
                                let _ = position_window_at_tray(&app_handle, pos, size);
                            }

                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                }
            }
        })
        .build(app_handle)?;

    Ok(())
}

/// Tauri command to update tray menu from frontend
#[tauri::command]
pub fn refresh_tray_menu(app_handle: tauri::AppHandle) -> Result<(), String> {
    update_tray_menu(&app_handle).map_err(|e| e.to_string())
}
