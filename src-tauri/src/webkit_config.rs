//! WebKit configuration for disabling background suspension on macOS.
//!
//! By default, WebKit suspends JavaScript execution when the webview is not visible.
//! This module disables that behavior so auto-update timers continue to fire.

use tauri::Manager;

pub fn disable_webview_suspension(app_handle: &tauri::AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        log::warn!("webkit_config: main window not found");
        return;
    };

    if let Err(e) = window.with_webview(|webview| {
        unsafe {
            use objc2_web_kit::{WKInactiveSchedulingPolicy, WKWebView};
            let wk_webview: &WKWebView = &*webview.inner().cast();
            let config = wk_webview.configuration();
            let prefs = config.preferences();
            prefs.setInactiveSchedulingPolicy(WKInactiveSchedulingPolicy::None);
            log::info!("WebKit inactiveSchedulingPolicy set to None");
        }
    }) {
        log::warn!("Failed to configure WebKit scheduling: {e}");
    }
}
