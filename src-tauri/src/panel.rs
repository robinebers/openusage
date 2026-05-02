#[cfg(target_os = "macos")]
#[path = "panel_macos.rs"]
mod platform;

#[cfg(not(target_os = "macos"))]
#[path = "panel_standard.rs"]
mod platform;

#[cfg(target_os = "windows")]
pub use platform::{hide_panel, init, show_panel, toggle_panel};

#[cfg(not(target_os = "windows"))]
pub use platform::{
    hide_panel, init, is_visible, show_panel, show_panel_at_tray_icon, toggle_panel,
};
