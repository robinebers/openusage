use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Settings {
    pub providers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyEntry {
    pub key: String,
    #[serde(rename = "keyName")]
    pub key_name: String,
}

pub fn config_dir() -> PathBuf {
    dirs::home_dir()
        .expect("no home directory")
        .join(".openusage")
}

pub fn settings_path() -> PathBuf {
    settings_path_from(&config_dir())
}

pub fn keys_path() -> PathBuf {
    keys_path_from(&config_dir())
}

pub fn settings_path_from(base: &Path) -> PathBuf {
    base.join("settings.json")
}

pub fn keys_path_from(base: &Path) -> PathBuf {
    base.join("env").join("keys.json")
}

pub fn load_settings() -> Option<Settings> {
    load_settings_from(&config_dir())
}

pub fn load_settings_from(base: &Path) -> Option<Settings> {
    let path = settings_path_from(base);
    if !path.exists() {
        return None;
    }
    let content = std::fs::read_to_string(&path).ok()?;
    serde_json::from_str(&content).ok()
}

pub fn save_settings(settings: &Settings) -> std::io::Result<()> {
    save_settings_to(settings, &config_dir())
}

pub fn save_settings_to(settings: &Settings, base: &Path) -> std::io::Result<()> {
    let path = settings_path_from(base);
    std::fs::create_dir_all(path.parent().unwrap())?;
    let json = serde_json::to_string_pretty(settings)?;
    std::fs::write(&path, json)
}

pub fn load_keys() -> HashMap<String, KeyEntry> {
    load_keys_from(&config_dir())
}

pub fn load_keys_from(base: &Path) -> HashMap<String, KeyEntry> {
    let path = keys_path_from(base);
    if !path.exists() {
        return HashMap::new();
    }
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return HashMap::new(),
    };
    serde_json::from_str(&content).unwrap_or_default()
}

pub fn save_keys(keys: &HashMap<String, KeyEntry>) -> std::io::Result<()> {
    save_keys_to(keys, &config_dir())
}

pub fn save_keys_to(keys: &HashMap<String, KeyEntry>, base: &Path) -> std::io::Result<()> {
    let path = keys_path_from(base);
    std::fs::create_dir_all(path.parent().unwrap())?;
    let json = serde_json::to_string_pretty(keys)?;
    std::fs::write(&path, json)
}

pub fn add_provider(provider_id: &str) -> std::io::Result<()> {
    add_provider_to(provider_id, &config_dir())
}

pub fn add_provider_to(provider_id: &str, base: &Path) -> std::io::Result<()> {
    let mut settings = load_settings_from(base).unwrap_or_default();
    if !settings.providers.contains(&provider_id.to_string()) {
        settings.providers.push(provider_id.to_string());
    }
    save_settings_to(&settings, base)
}

pub fn remove_provider(provider_id: &str) -> std::io::Result<bool> {
    remove_provider_from(provider_id, &config_dir())
}

pub fn remove_provider_from(provider_id: &str, base: &Path) -> std::io::Result<bool> {
    let mut settings = load_settings_from(base).unwrap_or_default();
    let before = settings.providers.len();
    settings.providers.retain(|p| p != provider_id);
    let removed = settings.providers.len() < before;
    save_settings_to(&settings, base)?;
    Ok(removed)
}

pub fn inject_env_keys(provider_id: &str, env_var_names: &[String]) {
    inject_env_keys_from(provider_id, env_var_names, &config_dir())
}

pub fn inject_env_keys_from(provider_id: &str, env_var_names: &[String], base: &Path) {
    let keys = load_keys_from(base);
    if let Some(entry) = keys.get(provider_id) {
        for var in env_var_names {
            // SAFETY: This is called during single-threaded CLI setup before
            // any worker threads are spawned, so no data race is possible.
            unsafe {
                std::env::set_var(var, &entry.key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "openusage-test-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn load_settings_returns_none_when_no_file() {
        let base = temp_dir("no-settings");
        assert!(load_settings_from(&base).is_none());
    }

    #[test]
    fn save_and_load_settings_round_trip() {
        let base = temp_dir("settings-rt");
        let settings = Settings {
            providers: vec!["claude".to_string(), "copilot".to_string()],
        };
        save_settings_to(&settings, &base).unwrap();
        let loaded = load_settings_from(&base).expect("should load");
        assert_eq!(loaded.providers, vec!["claude", "copilot"]);
    }

    #[test]
    fn add_provider_appends_without_duplicates() {
        let base = temp_dir("add-provider");
        add_provider_to("claude", &base).unwrap();
        add_provider_to("copilot", &base).unwrap();
        add_provider_to("claude", &base).unwrap(); // duplicate

        let settings = load_settings_from(&base).unwrap();
        assert_eq!(settings.providers, vec!["claude", "copilot"]);
    }

    #[test]
    fn remove_provider_returns_true_when_found() {
        let base = temp_dir("remove-found");
        add_provider_to("claude", &base).unwrap();
        add_provider_to("copilot", &base).unwrap();

        let removed = remove_provider_from("claude", &base).unwrap();
        assert!(removed);

        let settings = load_settings_from(&base).unwrap();
        assert_eq!(settings.providers, vec!["copilot"]);
    }

    #[test]
    fn remove_provider_returns_false_when_not_found() {
        let base = temp_dir("remove-not-found");
        add_provider_to("claude", &base).unwrap();

        let removed = remove_provider_from("gemini", &base).unwrap();
        assert!(!removed);
    }

    #[test]
    fn save_and_load_keys_round_trip() {
        let base = temp_dir("keys-rt");
        let mut keys = HashMap::new();
        keys.insert(
            "minimax".to_string(),
            KeyEntry {
                key: "sk-abc123".to_string(),
                key_name: "MiniMax API Key".to_string(),
            },
        );
        save_keys_to(&keys, &base).unwrap();
        let loaded = load_keys_from(&base);
        assert_eq!(loaded.len(), 1);
        let entry = loaded.get("minimax").expect("should have minimax");
        assert_eq!(entry.key, "sk-abc123");
        assert_eq!(entry.key_name, "MiniMax API Key");
    }

    #[test]
    fn load_keys_returns_empty_when_no_file() {
        let base = temp_dir("no-keys");
        let keys = load_keys_from(&base);
        assert!(keys.is_empty());
    }

    #[test]
    fn inject_env_keys_sets_env_vars() {
        let base = temp_dir("inject-keys");
        let mut keys = HashMap::new();
        keys.insert(
            "minimax".to_string(),
            KeyEntry {
                key: "test-key-value".to_string(),
                key_name: "MiniMax API Key".to_string(),
            },
        );
        save_keys_to(&keys, &base).unwrap();

        let var_names = vec![
            "OPENUSAGE_TEST_MINIMAX_KEY".to_string(),
            "OPENUSAGE_TEST_MINIMAX_CN_KEY".to_string(),
        ];
        inject_env_keys_from("minimax", &var_names, &base);

        assert_eq!(
            std::env::var("OPENUSAGE_TEST_MINIMAX_KEY").unwrap(),
            "test-key-value"
        );
        assert_eq!(
            std::env::var("OPENUSAGE_TEST_MINIMAX_CN_KEY").unwrap(),
            "test-key-value"
        );
    }
}
