pub mod host_api;
pub mod manifest;
pub mod runtime;

use base64::{
    Engine as _,
    engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD},
};
use manifest::LoadedPlugin;
use std::path::{Path, PathBuf};

const OPENUSAGE_CODEX_ACCOUNTS_DIR: &str = ".openusage/codex-accounts";
const OPENUSAGE_SLOT_PLUGIN_PREFIX: &str = "codex-slot-";

pub fn initialize_plugins(
    app_data_dir: &Path,
    resource_dir: &Path,
) -> (PathBuf, Vec<LoadedPlugin>) {
    if let Some(dev_dir) = find_dev_plugins_dir() {
        if !is_dir_empty(&dev_dir) {
            let mut plugins = manifest::load_plugins_from_dir(&dev_dir);
            add_codex_account_plugins(&mut plugins);
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

    let mut plugins = manifest::load_plugins_from_dir(&install_dir);
    add_codex_account_plugins(&mut plugins);
    (install_dir, plugins)
}

fn add_codex_account_plugins(plugins: &mut Vec<LoadedPlugin>) {
    let Some(codex) = plugins
        .iter()
        .find(|plugin| plugin.manifest.id == "codex")
        .cloned()
    else {
        return;
    };

    let Some(home) = dirs::home_dir() else {
        return;
    };

    let mut known_accounts = Vec::new();
    if let Some(codex_account) = read_primary_codex_account_label(&home) {
        known_accounts.push(codex_account);
    }

    for (slot_name, account_label) in read_openusage_codex_slots(&home) {
        if account_exists(&known_accounts, &account_label) {
            continue;
        }
        known_accounts.push(account_label.clone());
        let plugin_id = format!("{}{}", OPENUSAGE_SLOT_PLUGIN_PREFIX, slot_name);
        push_codex_account_plugin(plugins, &codex, plugin_id, account_label);
    }

    let hermes_auth_path = home.join(".hermes").join("auth.json");
    if let Some(hermes_account) = read_hermes_codex_account_label(&hermes_auth_path) {
        if !account_exists(&known_accounts, &hermes_account) {
            push_codex_account_plugin(
                plugins,
                &codex,
                "codex-hermes".to_string(),
                hermes_account,
            );
        }
    }

    plugins.sort_by(|a, b| a.manifest.id.cmp(&b.manifest.id));
}

fn push_codex_account_plugin(
    plugins: &mut Vec<LoadedPlugin>,
    base: &LoadedPlugin,
    plugin_id: String,
    account_label: String,
) {
    if plugins.iter().any(|plugin| plugin.manifest.id == plugin_id) {
        return;
    }
    let mut account_plugin = base.clone();
    account_plugin.manifest.id = plugin_id;
    account_plugin.manifest.name = account_label;
    plugins.push(account_plugin);
}

fn account_exists(existing: &[String], candidate: &str) -> bool {
    existing
        .iter()
        .any(|account| account.eq_ignore_ascii_case(candidate))
}

fn read_openusage_codex_slots(home: &Path) -> Vec<(String, String)> {
    let accounts_dir = home.join(OPENUSAGE_CODEX_ACCOUNTS_DIR);
    let Ok(entries) = std::fs::read_dir(accounts_dir) else {
        return Vec::new();
    };

    let mut slots = Vec::new();
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_dir() {
            continue;
        }
        let slot_name = entry.file_name().to_string_lossy().to_string();
        if !is_safe_slot_name(&slot_name) {
            continue;
        }
        let auth_path = entry.path().join("auth.json");
        if let Some(account_label) = read_codex_auth_account_label(&auth_path) {
            slots.push((slot_name, account_label));
        }
    }
    slots.sort_by(|a, b| a.0.cmp(&b.0));
    slots
}

fn is_safe_slot_name(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
}

fn read_primary_codex_account_label(home: &Path) -> Option<String> {
    if let Ok(codex_home) = std::env::var("CODEX_HOME") {
        let trimmed = codex_home.trim();
        if !trimmed.is_empty() {
            return read_codex_auth_account_label(&PathBuf::from(trimmed).join("auth.json"));
        }
    }

    for auth_path in [
        home.join(".config").join("codex").join("auth.json"),
        home.join(".codex").join("auth.json"),
    ] {
        if let Some(label) = read_codex_auth_account_label(&auth_path) {
            return Some(label);
        }
    }

    None
}

fn read_codex_auth_account_label(auth_path: &Path) -> Option<String> {
    let root = read_json_file(auth_path)?;
    let id_token = root
        .get("tokens")?
        .get("id_token")?
        .as_str()?;
    account_label_from_id_token(id_token)
}

fn read_hermes_codex_account_label(auth_path: &Path) -> Option<String> {
    let root = read_json_file(auth_path)?;
    let id_token = root
        .get("providers")?
        .get("openai-codex")?
        .get("tokens")?
        .get("id_token")?
        .as_str()?;
    account_label_from_id_token(id_token)
}

fn read_json_file(path: &Path) -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

fn account_label_from_id_token(id_token: &str) -> Option<String> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| URL_SAFE.decode(payload))
        .ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    for key in ["email", "name"] {
        if let Some(label) = value.get(key).and_then(|value| value.as_str()) {
            let trimmed = label.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
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
