pub mod host_api;
pub mod manifest;
pub mod runtime;

use manifest::LoadedPlugin;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PluginLoadMode {
    Default,
    MockOnly,
}

pub fn initialize_plugins(
    app_data_dir: &Path,
    resource_dir: &Path,
) -> (PathBuf, Vec<LoadedPlugin>) {
    let cwd = std::env::current_dir().ok();
    initialize_plugins_with_mode(
        app_data_dir,
        resource_dir,
        plugin_load_mode_from_env(),
        cwd.as_deref(),
    )
}

fn initialize_plugins_with_mode(
    app_data_dir: &Path,
    resource_dir: &Path,
    mode: PluginLoadMode,
    cwd: Option<&Path>,
) -> (PathBuf, Vec<LoadedPlugin>) {
    if let Some(dev_dir) = find_dev_plugins_dir(cwd) {
        if !is_dir_empty(&dev_dir) {
            return match mode {
                PluginLoadMode::Default => {
                    let plugins = manifest::load_plugins_from_dir(&dev_dir);
                    (dev_dir, plugins)
                }
                PluginLoadMode::MockOnly => load_selected_plugins(&dev_dir, app_data_dir, &["mock"]),
            };
        }
    }

    let install_dir = app_data_dir.join("plugins");
    if let Err(err) = std::fs::create_dir_all(&install_dir) {
        log::warn!("failed to create install dir {}: {}", install_dir.display(), err);
    }

    let bundled_dir = resolve_bundled_dir(resource_dir);
    if bundled_dir.exists() {
        return match mode {
            PluginLoadMode::Default => {
                copy_dir_recursive(&bundled_dir, &install_dir);
                let plugins = manifest::load_plugins_from_dir(&install_dir);
                (install_dir, plugins)
            }
            PluginLoadMode::MockOnly => load_selected_plugins(&bundled_dir, app_data_dir, &["mock"]),
        };
    }

    let plugins = manifest::load_plugins_from_dir(&install_dir);
    (install_dir, plugins)
}

fn plugin_load_mode_from_env() -> PluginLoadMode {
    let mode = std::env::var("USAGETRAY_PLUGIN_MODE")
        .or_else(|_| std::env::var("OPENUSAGE_WINDOWS_PLUGIN_MODE"));
    match mode {
        Ok(value) if value.eq_ignore_ascii_case("mock") => PluginLoadMode::MockOnly,
        _ => PluginLoadMode::Default,
    }
}

fn find_dev_plugins_dir(cwd: Option<&Path>) -> Option<PathBuf> {
    let cwd = cwd?;
    let direct = cwd.join("plugins");
    if direct.exists() {
        return Some(direct);
    }
    let parent = cwd.join("..").join("plugins");
    if parent.exists() {
        return Some(parent);
    }
    None
}

fn resolve_bundled_dir(resource_dir: &Path) -> PathBuf {
    let nested = resource_dir.join("resources/bundled_plugins");
    if nested.exists() {
        nested
    } else {
        resource_dir.join("bundled_plugins")
    }
}

fn load_selected_plugins(
    source_root: &Path,
    app_data_dir: &Path,
    plugin_ids: &[&str],
) -> (PathBuf, Vec<LoadedPlugin>) {
    let install_dir = app_data_dir.join("plugins");
    reset_dir(&install_dir);

    for plugin_id in plugin_ids {
        let source_dir = source_root.join(plugin_id);
        if !source_dir.exists() {
            log::warn!(
                "requested plugin '{}' missing from {}",
                plugin_id,
                source_root.display()
            );
            continue;
        }

        if let Err(err) = std::fs::create_dir_all(install_dir.join(plugin_id)) {
            log::warn!(
                "failed to create selected plugin dir {}: {}",
                install_dir.join(plugin_id).display(),
                err
            );
            continue;
        }

        copy_dir_recursive(&source_dir, &install_dir.join(plugin_id));
    }

    let plugins = manifest::load_plugins_from_dir(&install_dir);
    (install_dir, plugins)
}

fn reset_dir(path: &Path) {
    let _ = std::fs::remove_dir_all(path);
    if let Err(err) = std::fs::create_dir_all(path) {
        log::warn!("failed to create dir {}: {}", path.display(), err);
    }
}

fn is_dir_empty(path: &Path) -> bool {
    match std::fs::read_dir(path) {
        Ok(mut entries) => entries.next().is_none(),
        Err(err) => {
            log::warn!("failed to read dir {}: {}", path.display(), err);
            true
        }
    }
}

fn copy_dir_recursive(src: &Path, dst: &Path) {
    match std::fs::read_dir(src) {
        Ok(entries) => {
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(err) => {
                        log::warn!("failed to read entry in {}: {}", src.display(), err);
                        continue;
                    }
                };
                let src_path = entry.path();
                let dst_path = dst.join(entry.file_name());
                let file_type = match entry.file_type() {
                    Ok(file_type) => file_type,
                    Err(err) => {
                        log::warn!("failed to read file type for {}: {}", src_path.display(), err);
                        continue;
                    }
                };
                if file_type.is_symlink() {
                    continue;
                }
                if file_type.is_dir() {
                    if let Err(err) = std::fs::create_dir_all(&dst_path) {
                        log::warn!(
                            "failed to create dir {}: {}",
                            dst_path.display(),
                            err
                        );
                        continue;
                    }
                    copy_dir_recursive(&src_path, &dst_path);
                } else if file_type.is_file() {
                    if let Err(err) = std::fs::copy(&src_path, &dst_path) {
                        log::warn!(
                            "failed to copy {} to {}: {}",
                            src_path.display(),
                            dst_path.display(),
                            err
                        );
                    }
                }
            }
        }
        Err(err) => {
            log::warn!("failed to read dir {}: {}", src.display(), err);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{initialize_plugins_with_mode, PluginLoadMode};
    use std::path::{Path, PathBuf};

    fn create_plugin(root: &Path, id: &str) {
        let plugin_dir = root.join(id);
        std::fs::create_dir_all(&plugin_dir).expect("create plugin dir");
        std::fs::write(
            plugin_dir.join("plugin.json"),
            format!(
                r#"{{
  "schemaVersion": 1,
  "id": "{id}",
  "name": "{id}",
  "version": "0.0.1",
  "entry": "plugin.js",
  "icon": "icon.svg",
  "brandColor": null,
  "lines": [
    {{ "type": "progress", "label": "Usage", "scope": "overview", "primaryOrder": 1 }}
  ]
}}"#
            ),
        )
        .expect("write manifest");
        std::fs::write(
            plugin_dir.join("plugin.js"),
            format!(r#"globalThis.__openusage_plugin = {{ id: "{id}", probe() {{ return {{ lines: [] }} }} }}"#),
        )
        .expect("write entry script");
        std::fs::write(
            plugin_dir.join("icon.svg"),
            r#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#,
        )
        .expect("write icon");
    }

    fn unique_temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "usage-tray-plugin-engine-{}-{}",
            name,
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    #[test]
    fn default_mode_uses_all_dev_plugins() {
        let root = unique_temp_dir("default");
        let cwd = root.join("workspace");
        let app_data_dir = root.join("app-data");
        let resource_dir = root.join("resources");
        let plugins_dir = cwd.join("plugins");

        std::fs::create_dir_all(&plugins_dir).expect("create plugins dir");
        create_plugin(&plugins_dir, "codex");
        create_plugin(&plugins_dir, "mock");

        let (_, plugins) = initialize_plugins_with_mode(
            &app_data_dir,
            &resource_dir,
            PluginLoadMode::Default,
            Some(&cwd),
        );

        let ids: Vec<_> = plugins.iter().map(|plugin| plugin.manifest.id.as_str()).collect();
        assert_eq!(ids, vec!["codex", "mock"]);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mock_mode_reduces_plugin_set_to_mock_only() {
        let root = unique_temp_dir("mock-only");
        let cwd = root.join("workspace");
        let app_data_dir = root.join("app-data");
        let resource_dir = root.join("resources");
        let plugins_dir = cwd.join("plugins");

        std::fs::create_dir_all(&plugins_dir).expect("create plugins dir");
        create_plugin(&plugins_dir, "codex");
        create_plugin(&plugins_dir, "mock");

        let (install_dir, plugins) = initialize_plugins_with_mode(
            &app_data_dir,
            &resource_dir,
            PluginLoadMode::MockOnly,
            Some(&cwd),
        );

        let ids: Vec<_> = plugins.iter().map(|plugin| plugin.manifest.id.as_str()).collect();
        assert_eq!(ids, vec!["mock"]);
        assert!(install_dir.join("mock").exists());
        assert!(!install_dir.join("codex").exists());

        let _ = std::fs::remove_dir_all(root);
    }
}
