//! WebKit configuration for macOS panel behavior.
//!
//! We keep JavaScript active while the panel is hidden and force the WKWebView
//! itself fully transparent so native liquid-glass can show through the app
//! container instead of only around it.

use tauri::Manager;

/// Returns true if the running macOS version is at least `major.minor`.
fn macos_at_least(major: u64, minor: u64) -> bool {
    let info = objc2_foundation::NSProcessInfo::processInfo();
    let version = info.operatingSystemVersion();
    (version.majorVersion as u64, version.minorVersion as u64) >= (major, minor)
}

pub fn configure_webview(app_handle: &tauri::AppHandle) {
    let Some(window) = app_handle.get_webview_window("main") else {
        log::warn!("webkit_config: main window not found");
        return;
    };

    let can_disable_inactive_scheduling = macos_at_least(14, 0);
    if !can_disable_inactive_scheduling {
        log::info!("WebKit inactiveSchedulingPolicy requires macOS 14.0+; skipping on this system");
    }

    if let Err(e) = window.with_webview(move |webview| unsafe {
        use objc2::sel;
        use objc2_app_kit::NSColor;
        use objc2_foundation::{NSNumber, NSObjectNSKeyValueCoding, NSObjectProtocol, ns_string};
        use objc2_web_kit::{WKInactiveSchedulingPolicy, WKWebView};

        let wk_webview: &WKWebView = &*webview.inner().cast();
        let clear = NSColor::clearColor();
        let no = NSNumber::numberWithBool(false);
        let config = wk_webview.configuration();
        let prefs = config.preferences();

        if can_disable_inactive_scheduling {
            prefs.setInactiveSchedulingPolicy(WKInactiveSchedulingPolicy::None);
        }

        config.setValue_forKey(Some(&no), ns_string!("drawsBackground"));
        wk_webview.setValue_forKey(Some(&no), ns_string!("drawsBackground"));

        if wk_webview.respondsToSelector(sel!(setUnderPageBackgroundColor:)) {
            wk_webview.setUnderPageBackgroundColor(Some(&clear));
        }

        if let Some(scroll_view) = wk_webview.enclosingScrollView() {
            scroll_view.setDrawsBackground(false);
            scroll_view.setBackgroundColor(&clear);

            let clip_view = scroll_view.contentView();
            clip_view.setDrawsBackground(false);
            clip_view.setBackgroundColor(&clear);
        }

        if let Some(ns_window) = wk_webview.window() {
            ns_window.setOpaque(false);
            ns_window.setBackgroundColor(Some(&clear));
        }

        log::info!("Configured transparent WKWebView and disabled inactive scheduling");
    }) {
        log::warn!("Failed to configure WebKit scheduling: {e}");
    }
}
