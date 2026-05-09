#[cfg(target_os = "macos")]
#[path = "panel_macos.rs"]
mod platform;

#[cfg(not(target_os = "macos"))]
#[path = "panel_windows.rs"]
mod platform;

pub use platform::{
    hide_panel, init, is_panel_visible, position_panel_at_tray_icon, show_panel, toggle_panel,
};
