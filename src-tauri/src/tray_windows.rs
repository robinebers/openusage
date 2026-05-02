use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::path::BaseDirectory;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

use crate::panel::show_panel;

const TRAY_ICON_PATH: &str = "icons/icon.png";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MenuItemSpec {
    id: &'static str,
    label: &'static str,
    enabled: bool,
}

fn menu_item_specs() -> [MenuItemSpec; 4] {
    [
        MenuItemSpec {
            id: "title",
            label: "OpenUsage",
            enabled: false,
        },
        MenuItemSpec {
            id: "open",
            label: "Open",
            enabled: true,
        },
        MenuItemSpec {
            id: "restart",
            label: "Restart",
            enabled: true,
        },
        MenuItemSpec {
            id: "quit",
            label: "Quit",
            enabled: true,
        },
    ]
}

pub fn create(app_handle: &AppHandle) -> tauri::Result<()> {
    let tray_icon_path = app_handle.path().resolve(TRAY_ICON_PATH, BaseDirectory::Resource)?;
    let icon = Image::from_path(tray_icon_path)?;

    let [title_spec, open_spec, restart_spec, quit_spec] = menu_item_specs();
    let title = MenuItem::with_id(
        app_handle,
        title_spec.id,
        title_spec.label,
        title_spec.enabled,
        None::<&str>,
    )?;
    let separator = PredefinedMenuItem::separator(app_handle)?;
    let open = MenuItem::with_id(
        app_handle,
        open_spec.id,
        open_spec.label,
        open_spec.enabled,
        None::<&str>,
    )?;
    let restart = MenuItem::with_id(
        app_handle,
        restart_spec.id,
        restart_spec.label,
        restart_spec.enabled,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(
        app_handle,
        quit_spec.id,
        quit_spec.label,
        quit_spec.enabled,
        None::<&str>,
    )?;
    let menu = Menu::with_items(app_handle, &[&title, &separator, &open, &restart, &quit])?;

    TrayIconBuilder::with_id("tray")
        .icon(icon)
        .tooltip("OpenUsage")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if should_open_from_tray_event(&event) {
                show_panel(tray.app_handle());
            }
        })
        .on_menu_event(|app_handle, event| match event.id.as_ref() {
            "open" => show_panel(app_handle),
            "restart" => {
                log::info!("restart requested via tray");
                app_handle.restart();
            }
            "quit" => {
                log::info!("quit requested via tray");
                app_handle.exit(0);
            }
            _ => {}
        })
        .build(app_handle)?;

    Ok(())
}

fn should_open_from_tray_event(event: &TrayIconEvent) -> bool {
    match event {
        TrayIconEvent::Click {
            button,
            button_state,
            ..
        } => should_open_from_mouse(*button, *button_state),
        _ => false,
    }
}

fn should_open_from_mouse(button: MouseButton, button_state: MouseButtonState) -> bool {
    button == MouseButton::Left && button_state == MouseButtonState::Up
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_tray_menu_excludes_macos_widget_actions() {
        let ids: Vec<&str> = menu_item_specs().iter().map(|item| item.id).collect();

        assert_eq!(ids, ["title", "open", "restart", "quit"]);
        assert!(!ids.contains(&"show_stats"));
        assert!(!ids.contains(&"go_to_settings"));
        assert!(!ids.contains(&"log_error"));
        assert!(!ids.contains(&"about"));
    }

    #[test]
    fn windows_tray_open_rule_is_left_click_release_only() {
        assert!(should_open_from_mouse(MouseButton::Left, MouseButtonState::Up));
        assert!(!should_open_from_mouse(MouseButton::Right, MouseButtonState::Up));
        assert!(!should_open_from_mouse(MouseButton::Left, MouseButtonState::Down));
    }
}
