use crate::plugin_engine::runtime::{MetricLine, PluginOutput};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const CACHE_FILE_NAME: &str = "usage-api-cache.json";
const SETTINGS_FILE_NAME: &str = "settings.json";
const DEFAULT_ENABLED_PLUGINS: &[&str] = &["claude", "codex", "cursor"];

#[cfg(not(test))]
const CACHE_WRITE_DEBOUNCE: Duration = Duration::from_millis(500);
#[cfg(test)]
const CACHE_WRITE_DEBOUNCE: Duration = Duration::from_millis(10);
const CACHE_WRITE_RETRY_MAX_DELAY: Duration = Duration::from_secs(30);

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
    dirty_generation: u64,
    flushed_generation: u64,
    flush_scheduled: bool,
}

#[derive(Debug, PartialEq, Eq)]
enum CacheFlushResult {
    Idle,
    Flushed,
    Failed(String),
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
            dirty_generation: 0,
            flushed_generation: 0,
            flush_scheduled: false,
        })
    })
}

fn cache_write_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
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
            log::warn!(
                "failed to parse usage-api-cache.json: {}, starting empty",
                e
            );
            HashMap::new()
        }
    }
}

fn save_cache(
    app_data_dir: &Path,
    snapshots: &HashMap<String, CachedPluginSnapshot>,
) -> Result<(), String> {
    let file = UsageApiCacheFile {
        version: 1,
        snapshots: snapshots.clone(),
    };
    let path = app_data_dir.join(CACHE_FILE_NAME);
    let tmp_path = app_data_dir.join(".usage-api-cache.json.tmp");
    let json = serde_json::to_string(&file)
        .map_err(|e| format!("failed to serialize usage cache: {}", e))?;
    std::fs::write(&tmp_path, &json)
        .map_err(|e| format!("failed to write temp cache file: {}", e))?;
    std::fs::rename(&tmp_path, &path).map_err(|e| format!("failed to rename cache file: {}", e))?;
    Ok(())
}

fn schedule_cache_flush_locked(state: &mut CacheState) {
    if state.flush_scheduled {
        return;
    }

    state.flush_scheduled = true;
    std::thread::spawn(debounced_cache_flush_worker);
}

fn debounced_cache_flush_worker() {
    let mut consecutive_failures = 0_u32;
    let mut retry_delay = CACHE_WRITE_DEBOUNCE;

    loop {
        std::thread::sleep(retry_delay);

        match flush_pending_cache_once() {
            CacheFlushResult::Idle => return,
            CacheFlushResult::Flushed => {
                if consecutive_failures > 0 {
                    log::info!(
                        "usage-api-cache.json write recovered after {} failed attempts",
                        consecutive_failures
                    );
                }
                consecutive_failures = 0;
                retry_delay = CACHE_WRITE_DEBOUNCE;
            }
            CacheFlushResult::Failed(e) => {
                consecutive_failures = consecutive_failures.saturating_add(1);
                retry_delay = cache_write_retry_delay(consecutive_failures);
                if should_log_cache_write_failure(consecutive_failures) {
                    log::warn!(
                        "{}; retrying in {:?} (consecutive failures: {})",
                        e,
                        retry_delay,
                        consecutive_failures
                    );
                }
            }
        }
    }
}

fn cache_write_retry_delay(consecutive_failures: u32) -> Duration {
    let factor = 1_u32 << consecutive_failures.min(16);
    std::cmp::min(
        CACHE_WRITE_DEBOUNCE.saturating_mul(factor),
        CACHE_WRITE_RETRY_MAX_DELAY,
    )
}

fn should_log_cache_write_failure(consecutive_failures: u32) -> bool {
    consecutive_failures == 1 || consecutive_failures.is_power_of_two()
}

fn pending_cache_write() -> Option<(u64, PathBuf, HashMap<String, CachedPluginSnapshot>)> {
    let mut state = cache_state().lock().expect("cache state poisoned");
    if state.dirty_generation == state.flushed_generation {
        state.flush_scheduled = false;
        return None;
    }

    Some((
        state.dirty_generation,
        state.app_data_dir.clone(),
        state.snapshots.clone(),
    ))
}

fn mark_cache_flushed(generation: u64) {
    let mut state = cache_state().lock().expect("cache state poisoned");
    state.flushed_generation = generation;
}

fn flush_pending_cache_once() -> CacheFlushResult {
    let _write_guard = cache_write_lock()
        .lock()
        .expect("cache write lock poisoned");
    let Some((generation, app_data_dir, snapshots)) = pending_cache_write() else {
        return CacheFlushResult::Idle;
    };

    match save_cache(&app_data_dir, &snapshots) {
        Ok(()) => {
            mark_cache_flushed(generation);
            CacheFlushResult::Flushed
        }
        Err(e) => CacheFlushResult::Failed(e),
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
    state.dirty_generation = 0;
    state.flushed_generation = 0;
    state.flush_scheduled = false;
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
    state.snapshots.insert(output.provider_id.clone(), snapshot);
    state.dirty_generation = state.dirty_generation.wrapping_add(1);
    schedule_cache_flush_locked(&mut state);
}

pub fn flush_cache() {
    if let CacheFlushResult::Failed(e) = flush_pending_cache_once() {
        log::warn!("{}", e);
    }
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
    use crate::plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};
    use serial_test::serial;
    use std::time::Instant;

    fn make_snapshot(id: &str, name: &str) -> CachedPluginSnapshot {
        CachedPluginSnapshot {
            provider_id: id.to_string(),
            display_name: name.to_string(),
            plan: Some("Pro".to_string()),
            lines: vec![],
            fetched_at: "2026-03-26T08:15:30Z".to_string(),
        }
    }

    fn make_output(id: &str, name: &str) -> PluginOutput {
        PluginOutput {
            provider_id: id.to_string(),
            display_name: name.to_string(),
            plan: Some("Pro".to_string()),
            lines: vec![MetricLine::Text {
                label: "Usage".to_string(),
                value: "42%".to_string(),
                color: None,
                subtitle: None,
            }],
            icon_url: String::new(),
        }
    }

    fn temp_dir(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "openusage-test-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn wait_for_cached_snapshots(
        dir: &Path,
        expected_len: usize,
    ) -> HashMap<String, CachedPluginSnapshot> {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let loaded = load_cache(dir);
            if loaded.len() == expected_len {
                return loaded;
            }
            assert!(
                Instant::now() < deadline,
                "cache file was not flushed within the test deadline"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn wait_for_cache_writer_idle() {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let state = cache_state().lock().unwrap();
            if !state.flush_scheduled && state.dirty_generation == state.flushed_generation {
                return;
            }
            drop(state);
            assert!(
                Instant::now() < deadline,
                "debounced cache writer did not return to idle"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn cache_write_retry_delay_backs_off_and_caps() {
        assert_eq!(
            cache_write_retry_delay(1),
            CACHE_WRITE_DEBOUNCE.saturating_mul(2)
        );
        assert_eq!(
            cache_write_retry_delay(2),
            CACHE_WRITE_DEBOUNCE.saturating_mul(4)
        );
        assert_eq!(cache_write_retry_delay(20), CACHE_WRITE_RETRY_MAX_DELAY);
    }

    #[test]
    fn cache_write_failure_logs_are_throttled() {
        assert!(should_log_cache_write_failure(1));
        assert!(should_log_cache_write_failure(2));
        assert!(!should_log_cache_write_failure(3));
        assert!(should_log_cache_write_failure(4));
        assert!(!should_log_cache_write_failure(5));
        assert!(should_log_cache_write_failure(16));
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
        let dir = temp_dir("cache");
        std::fs::create_dir_all(&dir).unwrap();

        let mut snapshots = HashMap::new();
        snapshots.insert("claude".to_string(), make_snapshot("claude", "Claude"));

        save_cache(&dir, &snapshots).unwrap();
        let loaded = load_cache(&dir);

        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["claude"].provider_id, "claude");
        assert_eq!(loaded["claude"].fetched_at, "2026-03-26T08:15:30Z");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_cache_returns_empty_on_missing_file() {
        let dir = temp_dir("no-cache");
        let loaded = load_cache(&dir);
        assert!(loaded.is_empty());
    }

    #[test]
    fn load_cache_returns_empty_on_invalid_json() {
        let dir = temp_dir("bad-cache");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(CACHE_FILE_NAME), "not json").unwrap();

        let loaded = load_cache(&dir);
        assert!(loaded.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn cache_successful_output_debounces_disk_writes() {
        let dir = temp_dir("debounced-cache");
        std::fs::create_dir_all(&dir).unwrap();

        init(&dir, vec!["claude".to_string(), "codex".to_string()]);
        cache_successful_output(&make_output("claude", "Claude"));
        cache_successful_output(&make_output("codex", "Codex"));

        {
            let state = cache_state().lock().unwrap();
            assert!(state.flush_scheduled);
            assert_eq!(state.dirty_generation, 2);
            assert_eq!(state.flushed_generation, 0);
        }
        assert!(
            !dir.join(CACHE_FILE_NAME).exists(),
            "cache should not be written synchronously for every result"
        );

        let loaded = wait_for_cached_snapshots(&dir, 2);
        assert_eq!(loaded["claude"].display_name, "Claude");
        assert_eq!(loaded["codex"].display_name, "Codex");

        wait_for_cache_writer_idle();

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn flush_cache_persists_pending_write_synchronously() {
        let dir = temp_dir("flush-cache");
        std::fs::create_dir_all(&dir).unwrap();

        init(&dir, vec!["claude".to_string()]);
        cache_successful_output(&make_output("claude", "Claude"));
        assert!(
            !dir.join(CACHE_FILE_NAME).exists(),
            "cache write should be pending before explicit flush"
        );

        flush_cache();

        let loaded = load_cache(&dir);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["claude"].display_name, "Claude");

        wait_for_cache_writer_idle();

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn failed_cache_write_stays_pending_for_retry() {
        let dir = temp_dir("cache-write-retry");

        init(&dir, vec!["claude".to_string()]);
        {
            let mut state = cache_state().lock().unwrap();
            state
                .snapshots
                .insert("claude".to_string(), make_snapshot("claude", "Claude"));
            state.dirty_generation = 1;
            state.flushed_generation = 0;
            state.flush_scheduled = true;
        }

        assert!(matches!(
            flush_pending_cache_once(),
            CacheFlushResult::Failed(_)
        ));
        {
            let state = cache_state().lock().unwrap();
            assert_eq!(state.dirty_generation, 1);
            assert_eq!(state.flushed_generation, 0);
            assert!(state.flush_scheduled);
        }

        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(flush_pending_cache_once(), CacheFlushResult::Flushed);

        let loaded = load_cache(&dir);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["claude"].display_name, "Claude");

        assert_eq!(flush_pending_cache_once(), CacheFlushResult::Idle);
        {
            let state = cache_state().lock().unwrap();
            assert_eq!(state.dirty_generation, 1);
            assert_eq!(state.flushed_generation, 1);
            assert!(!state.flush_scheduled);
        }

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
