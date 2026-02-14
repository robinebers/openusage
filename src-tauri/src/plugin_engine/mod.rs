pub mod host_api;
pub mod manifest;
pub mod runtime;

use manifest::{LoadedPlugin, SupportedOs};
use std::path::{Path, PathBuf};

/// Get the current OS as a SupportedOs enum
fn current_os() -> SupportedOs {
    #[cfg(target_os = "macos")]
    return SupportedOs::Macos;
    #[cfg(target_os = "windows")]
    return SupportedOs::Windows;
    #[cfg(target_os = "linux")]
    return SupportedOs::Linux;
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    compile_error!("Unsupported target OS");
}

pub fn initialize_plugins(
    app_data_dir: &Path,
    resource_dir: &Path,
) -> (PathBuf, Vec<LoadedPlugin>) {
    let current = current_os();

    if let Some(dev_dir) = find_dev_plugins_dir() {
        if !is_dir_empty(&dev_dir) {
            let plugins = filter_plugins_by_os(manifest::load_plugins_from_dir(&dev_dir), current);
            return (dev_dir, plugins);
        }
    }

    let install_dir = app_data_dir.join("plugins");
    if let Err(err) = std::fs::create_dir_all(&install_dir) {
        log::warn!(
            "failed to create install dir {}: {}",
            install_dir.display(),
            err
        );
    }

    let bundled_dir = resolve_bundled_dir(resource_dir);
    if bundled_dir.exists() {
        copy_dir_recursive(&bundled_dir, &install_dir);
    }

    let plugins = filter_plugins_by_os(manifest::load_plugins_from_dir(&install_dir), current);
    (install_dir, plugins)
}

/// Filter plugins based on OS support. If no OS is specified, plugin is loaded on all platforms.
fn filter_plugins_by_os(plugins: Vec<LoadedPlugin>, current_os: SupportedOs) -> Vec<LoadedPlugin> {
    plugins
        .into_iter()
        .filter(|p| {
            let should_load = match &p.manifest.os {
                Some(supported_os_list) => supported_os_list.contains(&current_os),
                None => true, // No OS specified = all platforms
            };
            if !should_load {
                log::info!(
                    "skipping plugin '{}' - not supported on this OS",
                    p.manifest.id
                );
            }
            should_load
        })
        .collect()
}

fn find_dev_plugins_dir() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
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
                        log::warn!(
                            "failed to read file type for {}: {}",
                            src_path.display(),
                            err
                        );
                        continue;
                    }
                };
                if file_type.is_symlink() {
                    continue;
                }
                if file_type.is_dir() {
                    if let Err(err) = std::fs::create_dir_all(&dst_path) {
                        log::warn!("failed to create dir {}: {}", dst_path.display(), err);
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
