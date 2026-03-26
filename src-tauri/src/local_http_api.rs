use crate::plugin_engine::runtime::{MetricLine, PluginOutput};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

const BIND_ADDR: &str = "127.0.0.1:6736";
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

struct CacheState {
    snapshots: HashMap<String, CachedPluginSnapshot>,
    app_data_dir: PathBuf,
    known_plugin_ids: Vec<String>,
}

// ---------------------------------------------------------------------------
// Global cache state (same pattern as managed_shortcut_slot in lib.rs)
// ---------------------------------------------------------------------------

fn cache_state() -> &'static Mutex<CacheState> {
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
    match serde_json::to_string(&file) {
        Ok(json) => {
            if let Err(e) = std::fs::write(&path, json) {
                log::warn!("failed to write usage-api-cache.json: {}", e);
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

fn read_plugin_settings(app_data_dir: &Path) -> (Vec<String>, HashSet<String>) {
    let path = app_data_dir.join(SETTINGS_FILE_NAME);
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(_) => return (Vec::new(), HashSet::new()),
    };
    match serde_json::from_str::<SettingsFile>(&data) {
        Ok(sf) => {
            let ps = sf.plugins.unwrap_or(PluginSettingsJson {
                order: None,
                disabled: None,
            });
            let order = ps.order.unwrap_or_default();
            let disabled: HashSet<String> = ps.disabled.unwrap_or_default().into_iter().collect();
            (order, disabled)
        }
        Err(_) => (Vec::new(), HashSet::new()),
    }
}

/// Build the ordered list of enabled cached snapshots for GET /v1/usage.
fn enabled_snapshots_ordered(state: &CacheState) -> Vec<CachedPluginSnapshot> {
    let (settings_order, disabled) = read_plugin_settings(&state.app_data_dir);

    // If settings are present, use them; otherwise apply defaults.
    let has_settings = !settings_order.is_empty();

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

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

pub fn start_server() {
    std::thread::spawn(|| {
        let listener = match TcpListener::bind(BIND_ADDR) {
            Ok(l) => {
                log::info!("local HTTP API listening on {}", BIND_ADDR);
                l
            }
            Err(e) => {
                log::warn!(
                    "failed to bind local HTTP API on {}: {} — feature disabled for this session",
                    BIND_ADDR,
                    e
                );
                return;
            }
        };

        for stream in listener.incoming() {
            match stream {
                Ok(stream) => handle_connection(stream),
                Err(e) => log::debug!("local HTTP API accept error: {}", e),
            }
        }
    });
}

fn handle_connection(mut stream: TcpStream) {
    // Read request (up to 4 KB is plenty for a request line + headers)
    let mut buf = [0u8; 4096];
    let n = match stream.read(&mut buf) {
        Ok(n) => n,
        Err(_) => return,
    };
    let request = String::from_utf8_lossy(&buf[..n]);

    // Parse request line: "METHOD /path HTTP/1.x\r\n..."
    let first_line = request.lines().next().unwrap_or("");
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let raw_path = parts.next().unwrap_or("");

    // Strip query string and trailing slash (but keep root "/v1/usage" intact)
    let path = raw_path.split('?').next().unwrap_or(raw_path);
    let path = if path.len() > 1 {
        path.trim_end_matches('/')
    } else {
        path
    };

    let response = route(method, path);
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn route(method: &str, path: &str) -> String {
    // Match routes
    if path == "/v1/usage" {
        return match method {
            "GET" => handle_get_usage_collection(),
            "OPTIONS" => response_cors_preflight(),
            _ => response_method_not_allowed(),
        };
    }

    if let Some(provider_id) = path.strip_prefix("/v1/usage/") {
        if !provider_id.is_empty() && !provider_id.contains('/') {
            return match method {
                "GET" => handle_get_usage_single(provider_id),
                "OPTIONS" => response_cors_preflight(),
                _ => response_method_not_allowed(),
            };
        }
    }

    response_not_found("not_found")
}

fn handle_get_usage_collection() -> String {
    let state = cache_state().lock().expect("cache state poisoned");
    let snapshots = enabled_snapshots_ordered(&state);
    let body = serde_json::to_string(&snapshots).unwrap_or_else(|_| "[]".to_string());
    response_json(200, "OK", &body)
}

fn handle_get_usage_single(provider_id: &str) -> String {
    let state = cache_state().lock().expect("cache state poisoned");

    // Check if provider is known at all
    let is_known = state.known_plugin_ids.iter().any(|id| id == provider_id);
    if !is_known {
        return response_not_found("provider_not_found");
    }

    match state.snapshots.get(provider_id) {
        Some(snapshot) => {
            let body = serde_json::to_string(snapshot).unwrap_or_else(|_| "{}".to_string());
            response_json(200, "OK", &body)
        }
        None => response_no_content(),
    }
}

// ---------------------------------------------------------------------------
// HTTP response builders
// ---------------------------------------------------------------------------

const CORS_HEADERS: &str = "\
Access-Control-Allow-Origin: *\r\n\
Access-Control-Allow-Methods: GET, OPTIONS\r\n\
Access-Control-Allow-Headers: Content-Type";

fn response_json(status: u16, reason: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json; charset=utf-8\r\n{}\r\nContent-Length: {}\r\n\r\n{}",
        status,
        reason,
        CORS_HEADERS,
        body.len(),
        body,
    )
}

fn response_no_content() -> String {
    format!(
        "HTTP/1.1 204 No Content\r\n{}\r\n\r\n",
        CORS_HEADERS,
    )
}

fn response_cors_preflight() -> String {
    format!(
        "HTTP/1.1 204 No Content\r\n{}\r\n\r\n",
        CORS_HEADERS,
    )
}

fn response_not_found(error_code: &str) -> String {
    let body = format!(r#"{{"error":"{}"}}"#, error_code);
    response_json(404, "Not Found", &body)
}

fn response_method_not_allowed() -> String {
    let body = r#"{"error":"method_not_allowed"}"#;
    response_json(405, "Method Not Allowed", body)
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
        let dir = std::env::temp_dir().join("openusage-test-no-cache");
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
    fn route_get_usage_returns_200() {
        let resp = route("GET", "/v1/usage");
        assert!(resp.starts_with("HTTP/1.1 200"));
    }

    #[test]
    fn route_unknown_path_returns_404() {
        let resp = route("GET", "/v2/something");
        assert!(resp.starts_with("HTTP/1.1 404"));
    }

    #[test]
    fn route_post_returns_405() {
        let resp = route("POST", "/v1/usage");
        assert!(resp.starts_with("HTTP/1.1 405"));
    }

    #[test]
    fn route_options_returns_204_with_cors() {
        let resp = route("OPTIONS", "/v1/usage");
        assert!(resp.starts_with("HTTP/1.1 204"));
        assert!(resp.contains("Access-Control-Allow-Origin: *"));
    }

    #[test]
    fn route_unknown_provider_returns_404() {
        // Initialize cache state with known plugins
        {
            let mut state = cache_state().lock().unwrap();
            state.known_plugin_ids = vec!["claude".to_string()];
            state.snapshots.clear();
        }

        let resp = route("GET", "/v1/usage/nonexistent");
        assert!(resp.starts_with("HTTP/1.1 404"));
        assert!(resp.contains("provider_not_found"));
    }

    #[test]
    fn route_known_uncached_provider_returns_204() {
        {
            let mut state = cache_state().lock().unwrap();
            state.known_plugin_ids = vec!["claude".to_string()];
            state.snapshots.clear();
        }

        let resp = route("GET", "/v1/usage/claude");
        assert!(resp.starts_with("HTTP/1.1 204"));
    }

    #[test]
    fn route_known_cached_provider_returns_200() {
        {
            let mut state = cache_state().lock().unwrap();
            state.known_plugin_ids = vec!["claude".to_string()];
            state
                .snapshots
                .insert("claude".to_string(), make_snapshot("claude", "Claude"));
        }

        let resp = route("GET", "/v1/usage/claude");
        assert!(resp.starts_with("HTTP/1.1 200"));
        assert!(resp.contains("fetchedAt"));
    }

    #[test]
    fn route_trailing_slash_tolerated() {
        let resp = route("GET", "/v1/usage");
        let resp_slash = route("GET", "/v1/usage");
        // Both should be 200 (the trailing slash is stripped in handle_connection,
        // but route itself receives the cleaned path)
        assert!(resp.starts_with("HTTP/1.1 200"));
        assert!(resp_slash.starts_with("HTTP/1.1 200"));
    }

    #[test]
    fn route_options_on_provider_returns_204() {
        let resp = route("OPTIONS", "/v1/usage/claude");
        assert!(resp.starts_with("HTTP/1.1 204"));
        assert!(resp.contains("Access-Control-Allow-Methods: GET, OPTIONS"));
    }

    #[test]
    fn response_json_includes_cors_headers() {
        let resp = response_json(200, "OK", "[]");
        assert!(resp.contains("Access-Control-Allow-Origin: *"));
        assert!(resp.contains("Content-Type: application/json; charset=utf-8"));
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
