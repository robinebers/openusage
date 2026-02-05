//! App Nap prevention for macOS.
//!
//! macOS App Nap can suspend background processes to save energy.
//! This module prevents that so timers and background work continue.

use std::sync::Once;

use objc2::msg_send;
use objc2::rc::Retained;
use objc2_foundation::{NSObject, NSProcessInfo, NSString};

static INIT: Once = Once::new();

/// Disables App Nap by starting a background activity.
///
/// Tells macOS that the app needs periodic background work and should not
/// be suspended. The activity persists for the app's lifetime.
pub fn disable_app_nap() {
    INIT.call_once(|| {
        unsafe {
            let process_info = NSProcessInfo::processInfo();
            let options: u64 = 0xFF; // NSActivityBackground
            let reason = NSString::from_str("Periodic usage data refresh");
            let token: Retained<NSObject> = msg_send![
                &process_info,
                beginActivityWithOptions: options,
                reason: &*reason
            ];
            // Intentionally leak -- the activity token must persist for the app's lifetime.
            // Dropping it would re-enable App Nap.
            std::mem::forget(token);
            log::info!("App Nap disabled via NSProcessInfo background activity");
        }
    });
}
