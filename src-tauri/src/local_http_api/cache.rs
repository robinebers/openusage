use crate::plugin_engine::runtime::{MetricLine, PluginOutput};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

const CACHE_FILE_NAME: &str = "usage-api-cache.json";
const SETTINGS_FILE_NAME: &str = "settings.json";
const DEFAULT_ENABLED_PLUGINS: &[&str] = &["claude", "codex", "cursor"];

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedPluginSnapshot {
    pub provider_id: String,
    pub display_name: String,
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub fetched_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageApiCacheFile {
    version: u32,
    snapshots: HashMap<String, CachedPluginSnapshot>,
}

pub(super) struct CacheState {
    pub snapshots: HashMap<String, CachedPluginSnapshot>,
    pub app_data_dir: PathBuf,
    pub known_plugin_ids: Vec<String>,
}

// ---------------------------------------------------------------------------
// Global cache state (same pattern as managed_shortcut_slot in lib.rs)
// ---------------------------------------------------------------------------

pub(super) fn cache_state() -> &'static Mutex<CacheState> {
    static STATE: OnceLock<Mutex<CacheState>> = OnceLock::new();
    STATE.get_or_init(|| {
        Mutex::new(CacheState {
            snapshots: HashMap::new(),
            app_data_dir: PathBuf::new(),
            known_plugin_ids: Vec::new(),
        })
    })
}

// ---------------------------------------------------------------------------
// Cache persistence
// ---------------------------------------------------------------------------

pub fn load_cache(app_data_dir: &Path) -> HashMap<String, CachedPluginSnapshot> {
    let path = app_data_dir.join(CACHE_FILE_NAME);
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(_) => return HashMap::new(),
    };
    match serde_json::from_str::<UsageApiCacheFile>(&data) {
        Ok(file) if file.version == 1 => file.snapshots,
        Ok(_) => {
            log::warn!("usage-api-cache.json has unsupported version, starting empty");
            HashMap::new()
        }
        Err(e) => {
            log::warn!("failed to parse usage-api-cache.json: {}, starting empty", e);
            HashMap::new()
        }
    }
}

fn save_cache(app_data_dir: &Path, snapshots: &HashMap<String, CachedPluginSnapshot>) {
    let file = UsageApiCacheFile {
        version: 1,
        snapshots: snapshots.clone(),
    };
    let path = app_data_dir.join(CACHE_FILE_NAME);
    let tmp_path = app_data_dir.join(".usage-api-cache.json.tmp");
    match serde_json::to_string(&file) {
        Ok(json) => {
            if let Err(e) = std::fs::write(&tmp_path, &json) {
                log::warn!("failed to write temp cache file: {}", e);
                return;
            }
            if let Err(e) = std::fs::rename(&tmp_path, &path) {
                log::warn!("failed to rename cache file: {}", e);
            }
        }
        Err(e) => log::warn!("failed to serialize usage cache: {}", e),
    }
}

// ---------------------------------------------------------------------------
// Public API: initialise + update cache
// ---------------------------------------------------------------------------

pub fn init(app_data_dir: &Path, known_plugin_ids: Vec<String>) {
    let snapshots = load_cache(app_data_dir);
    let mut state = cache_state().lock().expect("cache state poisoned");
    state.snapshots = snapshots;
    state.app_data_dir = app_data_dir.to_path_buf();
    state.known_plugin_ids = known_plugin_ids;
}

pub fn cache_successful_output(output: &PluginOutput) {
    let fetched_at = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default();

    let snapshot = CachedPluginSnapshot {
        provider_id: output.provider_id.clone(),
        display_name: output.display_name.clone(),
        plan: output.plan.clone(),
        lines: output.lines.clone(),
        fetched_at,
    };

    let mut state = cache_state().lock().expect("cache state poisoned");
    state
        .snapshots
        .insert(output.provider_id.clone(), snapshot);
    save_cache(&state.app_data_dir, &state.snapshots);
}

// ---------------------------------------------------------------------------
// Settings reader (reads settings.json directly, not via tauri_plugin_store)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct SettingsFile {
    plugins: Option<PluginSettingsJson>,
}

#[derive(Deserialize)]
struct PluginSettingsJson {
    order: Option<Vec<String>>,
    disabled: Option<Vec<String>>,
}

fn read_plugin_settings(app_data_dir: &Path) -> (Vec<String>, HashSet<String>, bool) {
    let path = app_data_dir.join(SETTINGS_FILE_NAME);
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(_) => return (Vec::new(), HashSet::new(), false),
    };
    match serde_json::from_str::<SettingsFile>(&data) {
        Ok(sf) => {
            let ps = sf.plugins.unwrap_or(PluginSettingsJson {
                order: None,
                disabled: None,
            });
            let has_settings = ps.order.is_some() || ps.disabled.is_some();
            let order = ps.order.unwrap_or_default();
            let disabled: HashSet<String> = ps.disabled.unwrap_or_default().into_iter().collect();
            (order, disabled, has_settings)
        }
        Err(_) => (Vec::new(), HashSet::new(), false),
    }
}

/// Build the ordered list of enabled cached snapshots for GET /v1/usage.
pub(super) fn enabled_snapshots_ordered(state: &CacheState) -> Vec<CachedPluginSnapshot> {
    let (settings_order, disabled, has_settings) = read_plugin_settings(&state.app_data_dir);

    let default_enabled: HashSet<&str> = DEFAULT_ENABLED_PLUGINS.iter().copied().collect();

    let is_enabled = |id: &str| -> bool {
        if has_settings {
            !disabled.contains(id)
        } else {
            default_enabled.contains(id)
        }
    };

    // Build ordered plugin ids: settings order first, then remaining known ids.
    let mut ordered: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for id in &settings_order {
        if seen.insert(id.clone()) {
            ordered.push(id.clone());
        }
    }
    for id in &state.known_plugin_ids {
        if seen.insert(id.clone()) {
            ordered.push(id.clone());
        }
    }

    ordered
        .into_iter()
        .filter(|id| is_enabled(id))
        .filter_map(|id| state.snapshots.get(&id).cloned())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin_engine::runtime::ProgressFormat;

    fn make_snapshot(id: &str, name: &str) -> CachedPluginSnapshot {
        CachedPluginSnapshot {
            provider_id: id.to_string(),
            display_name: name.to_string(),
            plan: Some("Pro".to_string()),
            lines: vec![],
            fetched_at: "2026-03-26T08:15:30Z".to_string(),
        }
    }

    #[test]
    fn snapshot_serializes_with_fetched_at() {
        let snap = make_snapshot("claude", "Claude");
        let json: serde_json::Value = serde_json::to_value(&snap).unwrap();
        assert!(json.get("fetchedAt").is_some());
        assert!(json.get("fetched_at").is_none());
        assert_eq!(json["fetchedAt"], "2026-03-26T08:15:30Z");
    }

    #[test]
    fn cache_file_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "openusage-test-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();

        let mut snapshots = HashMap::new();
        snapshots.insert("claude".to_string(), make_snapshot("claude", "Claude"));

        save_cache(&dir, &snapshots);
        let loaded = load_cache(&dir);

        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["claude"].provider_id, "claude");
        assert_eq!(loaded["claude"].fetched_at, "2026-03-26T08:15:30Z");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_cache_returns_empty_on_missing_file() {
        let dir = std::env::temp_dir().join(format!(
            "openusage-test-no-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let loaded = load_cache(&dir);
        assert!(loaded.is_empty());
    }

    #[test]
    fn load_cache_returns_empty_on_invalid_json() {
        let dir = std::env::temp_dir().join(format!(
            "openusage-test-bad-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(CACHE_FILE_NAME), "not json").unwrap();

        let loaded = load_cache(&dir);
        assert!(loaded.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn snapshot_with_progress_line_round_trips() {
        let snap = CachedPluginSnapshot {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: Some("Max 20x".to_string()),
            lines: vec![crate::plugin_engine::runtime::MetricLine::Progress {
                label: "Session".to_string(),
                used: 42.0,
                limit: 100.0,
                format: ProgressFormat::Percent,
                resets_at: Some("2026-03-26T12:00:00Z".to_string()),
                period_duration_ms: Some(14400000),
                color: None,
            }],
            fetched_at: "2026-03-26T08:00:00Z".to_string(),
        };

        let json = serde_json::to_string(&snap).unwrap();
        let deserialized: CachedPluginSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.provider_id, "claude");
        assert_eq!(deserialized.lines.len(), 1);
    }
}
