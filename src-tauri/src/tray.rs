#[cfg(not(target_os = "windows"))]
#[path = "tray_non_windows.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "tray_windows.rs"]
mod platform;

pub use platform::create;
