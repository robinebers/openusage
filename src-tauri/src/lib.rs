#[cfg(target_os = "macos")]
mod app_nap;
mod cliproxyapi;
mod panel;
mod plugin_engine;
mod tray;
#[cfg(target_os = "macos")]
mod webkit_config;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde::Serialize;
use serde_json::Value;
use std::hash::{Hash, Hasher};
use tauri::Emitter;
use tauri_plugin_aptabase::EventTracker;
use tauri_plugin_log::{Target, TargetKind};
use uuid::Uuid;

#[cfg(desktop)]
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

const GLOBAL_SHORTCUT_STORE_KEY: &str = "globalShortcut";
const APP_STARTED_TRACKED_DAY_KEY_PREFIX: &str = "analytics.app_started_day.";

fn app_started_day_key(version: &str) -> String {
    format!("{}{}", APP_STARTED_TRACKED_DAY_KEY_PREFIX, version)
}

fn today_utc_ymd() -> String {
    let date = time::OffsetDateTime::now_utc().date();
    format!(
        "{:04}-{:02}-{:02}",
        date.year(),
        date.month() as u8,
        date.day()
    )
}

fn should_track_app_started(last_tracked_day: Option<&str>, today: &str) -> bool {
    match last_tracked_day {
        Some(day) => day != today,
        None => true,
    }
}

#[cfg(desktop)]
fn track_app_started_once_per_day_per_version(app: &tauri::App) {
    use tauri_plugin_store::StoreExt;

    let version = app.package_info().version.to_string();
    let key = app_started_day_key(&version);
    let today = today_utc_ymd();

    let store = match app.handle().store("settings.json") {
        Ok(store) => store,
        Err(error) => {
            log::warn!(
                "Failed to access settings store for app_started gate: {}",
                error
            );
            return;
        }
    };

    let last_tracked_day = store
        .get(&key)
        .and_then(|value| value.as_str().map(|value| value.to_string()));

    if !should_track_app_started(last_tracked_day.as_deref(), &today) {
        return;
    }

    let _ = app.track_event("app_started", None);

    store.set(&key, serde_json::Value::String(today));
    if let Err(error) = store.save() {
        log::warn!("Failed to save app_started tracked day: {}", error);
    }
}

#[cfg(not(desktop))]
fn track_app_started_once_per_day_per_version(app: &tauri::App) {
    let _ = app.track_event("app_started", None);
}

#[cfg(desktop)]
fn managed_shortcut_slot() -> &'static Mutex<Option<String>> {
    static SLOT: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

/// Shared shortcut handler that toggles the panel when the shortcut is pressed.
#[cfg(desktop)]
fn handle_global_shortcut(
    app: &tauri::AppHandle,
    event: tauri_plugin_global_shortcut::ShortcutEvent,
) {
    if event.state == ShortcutState::Pressed {
        log::debug!("Global shortcut triggered");
        panel::toggle_panel(app);
    }
}

pub struct AppState {
    pub plugins: Vec<plugin_engine::manifest::LoadedPlugin>,
    pub app_data_dir: PathBuf,
    pub app_version: String,
    pub cliproxy_credential_cache: Arc<Mutex<HashMap<String, String>>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginMeta {
    pub id: String,
    pub name: String,
    pub icon_url: String,
    pub brand_color: Option<String>,
    pub lines: Vec<ManifestLineDto>,
    pub links: Vec<PluginLinkDto>,
    /// Ordered list of primary metric candidates (sorted by primaryOrder).
    /// Frontend picks the first one that exists in runtime data.
    pub primary_candidates: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestLineDto {
    #[serde(rename = "type")]
    pub line_type: String,
    pub label: String,
    pub scope: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginLinkDto {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeBatchStarted {
    pub batch_id: String,
    pub plugin_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeResult {
    pub batch_id: String,
    pub output: plugin_engine::runtime::PluginOutput,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeBatchComplete {
    pub batch_id: String,
}

#[derive(Clone)]
struct PreparedCredentialOverlay {
    overlay: plugin_engine::host_api::SharedCredentialOverlay,
    cache_key: Option<String>,
}

fn expand_path(path: &str) -> String {
    if path == "~" {
        if let Some(home) = dirs::home_dir() {
            return home.to_string_lossy().to_string();
        }
    }
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest).to_string_lossy().to_string();
        }
    }
    path.to_string()
}

fn normalize_provider_key(provider: &str) -> String {
    let normalized = provider.trim().to_lowercase();
    match normalized.as_str() {
        "anthropic" => "claude".to_string(),
        "google" | "google-ai" | "gemini-cli" => "gemini".to_string(),
        _ => normalized,
    }
}

fn provider_matches_plugin(plugin_id: &str, provider: &str) -> bool {
    let provider_key = normalize_provider_key(provider);
    match plugin_id {
        "codex" => provider_key == "codex",
        "claude" => provider_key == "claude",
        "kimi" => provider_key == "kimi",
        "antigravity" => provider_key == "antigravity",
        "gemini" => provider_key == "gemini",
        _ => false,
    }
}

fn supports_credential_overlay(plugin_id: &str) -> bool {
    matches!(
        plugin_id,
        "codex" | "claude" | "kimi" | "antigravity" | "gemini"
    )
}

fn credential_target_paths(plugin_id: &str, app_data_dir: &PathBuf) -> Vec<String> {
    match plugin_id {
        "codex" => {
            if let Ok(codex_home) = std::env::var("CODEX_HOME") {
                let trimmed = codex_home.trim().trim_end_matches('/');
                if !trimmed.is_empty() {
                    return vec![format!("{}/auth.json", trimmed)];
                }
            }
            vec![
                "~/.config/codex/auth.json".to_string(),
                "~/.codex/auth.json".to_string(),
            ]
        }
        "claude" => vec!["~/.claude/.credentials.json".to_string()],
        "kimi" => vec!["~/.kimi/credentials/kimi-code.json".to_string()],
        "antigravity" => vec![
            app_data_dir
                .join("plugins_data")
                .join("antigravity")
                .join("auth.json")
                .to_string_lossy()
                .to_string(),
        ],
        "gemini" => vec!["~/.gemini/oauth_creds.json".to_string()],
        _ => Vec::new(),
    }
}

fn value_to_string(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        _ => None,
    }
}

fn parse_expiry_ms(expired: &str) -> i64 {
    let Ok(dt) =
        time::OffsetDateTime::parse(expired, &time::format_description::well_known::Rfc3339)
    else {
        return 0;
    };
    let millis = dt.unix_timestamp_nanos() / 1_000_000;
    i64::try_from(millis).unwrap_or(0)
}

fn parse_expiry_seconds(expired: &str) -> i64 {
    let ms = parse_expiry_ms(expired);
    if ms <= 0 {
        return 0;
    }
    ms / 1000
}

fn parse_epoch_to_ms(value: &str) -> Option<i64> {
    let parsed = value.trim().parse::<i64>().ok()?;
    if parsed > 10_000_000_000 {
        Some(parsed)
    } else if parsed > 0 {
        Some(parsed * 1000)
    } else {
        None
    }
}

fn read_string_field(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value_to_string(object.get(*key)))
}

fn transform_auth_payload_for_plugin(plugin_id: &str, raw_payload: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(raw_payload).map_err(|e| format!("invalid auth file JSON: {}", e))?;
    let object = parsed
        .as_object()
        .ok_or_else(|| "auth file JSON root must be an object".to_string())?;

    match plugin_id {
        "codex" => {
            let access_token = read_string_field(object, &["access_token", "accessToken"])
                .ok_or_else(|| "missing access_token".to_string())?;
            let refresh_token = read_string_field(object, &["refresh_token", "refreshToken"])
                .ok_or_else(|| "missing refresh_token".to_string())?;
            let id_token = read_string_field(object, &["id_token", "idToken"]);
            let account_id = read_string_field(object, &["account_id", "accountId"]);
            let last_refresh = read_string_field(object, &["last_refresh", "lastRefresh"])
                .unwrap_or_else(|| {
                    time::OffsetDateTime::now_utc()
                        .format(&time::format_description::well_known::Rfc3339)
                        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
                });

            let mut tokens = serde_json::Map::new();
            tokens.insert("access_token".to_string(), Value::String(access_token));
            tokens.insert("refresh_token".to_string(), Value::String(refresh_token));
            if let Some(id_token) = id_token {
                tokens.insert("id_token".to_string(), Value::String(id_token));
            }
            if let Some(account_id) = account_id {
                tokens.insert("account_id".to_string(), Value::String(account_id));
            }

            let mut out = serde_json::Map::new();
            out.insert("tokens".to_string(), Value::Object(tokens));
            out.insert("last_refresh".to_string(), Value::String(last_refresh));
            serde_json::to_string(&Value::Object(out))
                .map_err(|e| format!("failed to serialize transformed codex auth: {}", e))
        }
        "claude" => {
            let access_token = read_string_field(object, &["access_token", "accessToken"])
                .ok_or_else(|| "missing access_token".to_string())?;
            let refresh_token = read_string_field(object, &["refresh_token", "refreshToken"])
                .ok_or_else(|| "missing refresh_token".to_string())?;
            let expires_at = read_string_field(object, &["expired", "expires_at", "expiresAt"])
                .map(|raw| parse_expiry_ms(&raw))
                .unwrap_or(0);

            let mut oauth = serde_json::Map::new();
            oauth.insert("accessToken".to_string(), Value::String(access_token));
            oauth.insert("refreshToken".to_string(), Value::String(refresh_token));
            oauth.insert(
                "expiresAt".to_string(),
                Value::Number(serde_json::Number::from(expires_at)),
            );

            let mut out = serde_json::Map::new();
            out.insert("claudeAiOauth".to_string(), Value::Object(oauth));
            serde_json::to_string(&Value::Object(out))
                .map_err(|e| format!("failed to serialize transformed claude auth: {}", e))
        }
        "kimi" => {
            let access_token = read_string_field(object, &["access_token", "accessToken"])
                .ok_or_else(|| "missing access_token".to_string())?;
            let refresh_token = read_string_field(object, &["refresh_token", "refreshToken"])
                .ok_or_else(|| "missing refresh_token".to_string())?;
            let token_type = read_string_field(object, &["token_type", "tokenType"])
                .unwrap_or_else(|| "Bearer".to_string());
            let scope = read_string_field(object, &["scope"]);
            let device_id = read_string_field(object, &["device_id", "deviceId"]);
            let expired = read_string_field(object, &["expired", "expires_at", "expiresAt"]);
            let expires_at = read_string_field(object, &["expires_at", "expiresAt"])
                .and_then(|raw| raw.parse::<i64>().ok())
                .unwrap_or_else(|| expired.as_deref().map(parse_expiry_seconds).unwrap_or(0));

            let mut out = serde_json::Map::new();
            out.insert("access_token".to_string(), Value::String(access_token));
            out.insert("refresh_token".to_string(), Value::String(refresh_token));
            out.insert("token_type".to_string(), Value::String(token_type));
            out.insert(
                "expires_at".to_string(),
                Value::Number(serde_json::Number::from(expires_at)),
            );
            if let Some(scope) = scope {
                out.insert("scope".to_string(), Value::String(scope));
            }
            if let Some(device_id) = device_id {
                out.insert("device_id".to_string(), Value::String(device_id));
            }
            if let Some(expired) = expired {
                out.insert("expired".to_string(), Value::String(expired));
            }
            serde_json::to_string(&Value::Object(out))
                .map_err(|e| format!("failed to serialize transformed kimi auth: {}", e))
        }
        "antigravity" => {
            let access_token = read_string_field(object, &["access_token", "accessToken"])
                .ok_or_else(|| "missing access_token".to_string())?;
            let refresh_token = read_string_field(object, &["refresh_token", "refreshToken"]);
            let expires_at_ms = if let Some(expired) =
                read_string_field(object, &["expired", "expires_at", "expiresAt"])
            {
                let parsed = parse_expiry_ms(&expired);
                if parsed > 0 {
                    parsed
                } else {
                    let now_ms = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
                    let base_ms = i64::try_from(now_ms).unwrap_or(0);
                    let ttl_sec = read_string_field(object, &["expires_in", "expiresIn"])
                        .and_then(|raw| raw.parse::<i64>().ok())
                        .unwrap_or(3600);
                    base_ms + (ttl_sec * 1000)
                }
            } else {
                let now_ms = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
                let base_ms = i64::try_from(now_ms).unwrap_or(0);
                let ttl_sec = read_string_field(object, &["expires_in", "expiresIn"])
                    .and_then(|raw| raw.parse::<i64>().ok())
                    .unwrap_or(3600);
                base_ms + (ttl_sec * 1000)
            };

            let mut out = serde_json::Map::new();
            out.insert("accessToken".to_string(), Value::String(access_token));
            out.insert(
                "expiresAtMs".to_string(),
                Value::Number(serde_json::Number::from(expires_at_ms)),
            );
            if let Some(refresh_token) = refresh_token {
                out.insert("refreshToken".to_string(), Value::String(refresh_token));
            }
            if let Some(project_id) = read_string_field(object, &["project_id", "projectId"]) {
                out.insert("projectId".to_string(), Value::String(project_id));
            }
            if let Some(email) = read_string_field(object, &["email"]) {
                out.insert("email".to_string(), Value::String(email));
            }

            serde_json::to_string(&Value::Object(out))
                .map_err(|e| format!("failed to serialize transformed antigravity auth: {}", e))
        }
        "gemini" => {
            let token_object = object.get("token").and_then(|value| value.as_object());
            let access_token = read_string_field(object, &["access_token", "accessToken"])
                .or_else(|| token_object.and_then(|value| read_string_field(value, &["access_token", "accessToken"])));
            let refresh_token = read_string_field(object, &["refresh_token", "refreshToken"])
                .or_else(|| token_object.and_then(|value| read_string_field(value, &["refresh_token", "refreshToken"])));
            if access_token.is_none() && refresh_token.is_none() {
                return Err("missing access_token and refresh_token".to_string());
            }

            let expiry_date_ms = read_string_field(object, &["expiry_date", "expiryDate"])
                .as_deref()
                .and_then(parse_epoch_to_ms)
                .or_else(|| {
                    token_object
                        .and_then(|value| read_string_field(value, &["expiry_date", "expiryDate"]))
                        .as_deref()
                        .and_then(parse_epoch_to_ms)
                })
                .or_else(|| {
                    read_string_field(object, &["expired", "expires_at", "expiresAt"])
                        .as_deref()
                        .map(parse_expiry_ms)
                        .filter(|value| *value > 0)
                })
                .or_else(|| {
                    token_object
                        .and_then(|value| read_string_field(value, &["expiry", "expired", "expires_at", "expiresAt"]))
                        .as_deref()
                        .map(parse_expiry_ms)
                        .filter(|value| *value > 0)
                })
                .unwrap_or_else(|| {
                    let now_ms = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
                    let base_ms = i64::try_from(now_ms).unwrap_or(0);
                    let ttl_sec = read_string_field(object, &["expires_in", "expiresIn"])
                        .and_then(|raw| raw.parse::<i64>().ok())
                        .or_else(|| {
                            token_object
                                .and_then(|value| read_string_field(value, &["expires_in", "expiresIn"]))
                                .and_then(|raw| raw.parse::<i64>().ok())
                        })
                        .unwrap_or(3600);
                    base_ms + (ttl_sec * 1000)
                });

            let mut out = serde_json::Map::new();
            if let Some(access_token) = access_token {
                out.insert("access_token".to_string(), Value::String(access_token));
            }
            if let Some(refresh_token) = refresh_token {
                out.insert("refresh_token".to_string(), Value::String(refresh_token));
            }
            out.insert(
                "expiry_date".to_string(),
                Value::Number(serde_json::Number::from(expiry_date_ms)),
            );
            if let Some(id_token) = read_string_field(object, &["id_token", "idToken"])
                .or_else(|| token_object.and_then(|value| read_string_field(value, &["id_token", "idToken"])))
            {
                out.insert("id_token".to_string(), Value::String(id_token));
            }
            if let Some(client_id) = read_string_field(
                object,
                &["client_id", "clientId", "oauth_client_id", "oauthClientId"],
            )
            .or_else(|| {
                token_object.and_then(|value| {
                    read_string_field(value, &["client_id", "clientId", "oauth_client_id", "oauthClientId"])
                })
            }) {
                out.insert("client_id".to_string(), Value::String(client_id));
            }
            if let Some(client_secret) = read_string_field(
                object,
                &[
                    "client_secret",
                    "clientSecret",
                    "oauth_client_secret",
                    "oauthClientSecret",
                ],
            )
            .or_else(|| {
                token_object.and_then(|value| {
                    read_string_field(
                        value,
                        &[
                            "client_secret",
                            "clientSecret",
                            "oauth_client_secret",
                            "oauthClientSecret",
                        ],
                    )
                })
            }) {
                out.insert("client_secret".to_string(), Value::String(client_secret));
            }

            serde_json::to_string(&Value::Object(out))
                .map_err(|e| format!("failed to serialize transformed gemini auth: {}", e))
        }
        _ => Err("unsupported provider for credential overlay".to_string()),
    }
}

fn should_use_cached_overlay(plugin_id: &str, transformed: &str) -> bool {
    if plugin_id != "antigravity" && plugin_id != "gemini" {
        return true;
    }

    let Ok(parsed) = serde_json::from_str::<Value>(transformed) else {
        return false;
    };
    let Some(object) = parsed.as_object() else {
        return false;
    };

    let expires_at_ms = match plugin_id {
        "antigravity" => match object.get("expiresAtMs") {
            Some(Value::Number(n)) => n
                .as_i64()
                .or_else(|| n.as_u64().and_then(|u| i64::try_from(u).ok())),
            Some(Value::String(s)) => s.trim().parse::<i64>().ok(),
            _ => None,
        },
        "gemini" => object
            .get("expiry_date")
            .or_else(|| object.get("expiryDate"))
            .and_then(|value| match value {
                Value::Number(n) => n
                    .as_i64()
                    .or_else(|| n.as_u64().and_then(|u| i64::try_from(u).ok()))
                    .and_then(|raw| {
                        if raw > 10_000_000_000 {
                            Some(raw)
                        } else if raw > 0 {
                            Some(raw * 1000)
                        } else {
                            None
                        }
                    }),
                Value::String(s) => parse_epoch_to_ms(s),
                _ => None,
            }),
        _ => None,
    };
    let Some(expires_at_ms) = expires_at_ms else {
        return false;
    };

    let now_raw = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
    let now_ms = i64::try_from(now_raw).unwrap_or(0);
    let min_ttl_ms = 60_000i64;
    expires_at_ms > now_ms + min_ttl_ms
}

fn prepare_credential_overlay(
    plugin_id: &str,
    selection: &str,
    app_data_dir: &PathBuf,
    config: &cliproxyapi::CliProxyConfig,
    auth_files: &[cliproxyapi::CliProxyAuthFile],
    cache: &Arc<Mutex<HashMap<String, String>>>,
) -> Option<PreparedCredentialOverlay> {
    if !supports_credential_overlay(plugin_id) {
        return None;
    }

    let selected = selection.trim();
    if selected.is_empty() {
        return None;
    }

    let cache_key = format!(
        "{}::{}::{}",
        plugin_id,
        selected,
        config_cache_fingerprint(config)
    );
    let transformed = if let Ok(locked) = cache.lock() {
        if let Some(cached) = locked.get(&cache_key) {
            if should_use_cached_overlay(plugin_id, cached) {
                Some(cached.clone())
            } else {
                log::info!(
                    "CLIProxyAPI cached overlay expired for {} (selection={}), refreshing",
                    plugin_id,
                    selected
                );
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    let transformed = match transformed {
        Some(cached) => cached,
        None => {
            let auth_file = auth_files.iter().find(|entry| {
                let auth_index = entry.auth_index.as_deref().unwrap_or("");
                entry.id == selected || entry.name == selected || auth_index == selected
            })?;

            if auth_file.disabled || auth_file.unavailable {
                log::warn!(
                    "CLIProxyAPI auth file not usable for {}: {}",
                    plugin_id,
                    auth_file.name
                );
                return None;
            }

            if !provider_matches_plugin(plugin_id, &auth_file.provider) {
                log::warn!(
                    "CLIProxyAPI auth file provider mismatch for {}: {}",
                    plugin_id,
                    auth_file.provider
                );
                return None;
            }

            let raw = match cliproxyapi::download_auth_file_by_name(config, &auth_file.name) {
                Ok(raw) => raw,
                Err(err) => {
                    log::warn!(
                        "CLIProxyAPI download failed for {} ({}): {}",
                        plugin_id,
                        auth_file.name,
                        err
                    );
                    return None;
                }
            };

            let transformed = match transform_auth_payload_for_plugin(plugin_id, &raw) {
                Ok(transformed) => transformed,
                Err(err) => {
                    log::warn!(
                        "CLIProxyAPI transform failed for {} ({}): {}",
                        plugin_id,
                        auth_file.name,
                        err
                    );
                    return None;
                }
            };

            if let Ok(mut locked) = cache.lock() {
                locked.insert(cache_key.clone(), transformed.clone());
            }

            transformed
        }
    };

    let target_paths = credential_target_paths(plugin_id, app_data_dir);
    if target_paths.is_empty() {
        return None;
    }

    let mut overlay_map = HashMap::new();
    for path in target_paths {
        overlay_map.insert(path, transformed.clone());
    }

    Some(PreparedCredentialOverlay {
        overlay: Arc::new(Mutex::new(overlay_map)),
        cache_key: Some(cache_key),
    })
}

fn config_cache_fingerprint(config: &cliproxyapi::CliProxyConfig) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    config.api_key.hash(&mut hasher);
    let key_hash = hasher.finish();
    format!("{}::{:016x}", config.base_url, key_hash)
}

fn plugin_error_output(
    plugin: &plugin_engine::manifest::LoadedPlugin,
    message: impl Into<String>,
) -> plugin_engine::runtime::PluginOutput {
    plugin_engine::runtime::PluginOutput {
        provider_id: plugin.manifest.id.clone(),
        display_name: plugin.manifest.name.clone(),
        plan: None,
        lines: vec![plugin_engine::runtime::MetricLine::Badge {
            label: "Error".to_string(),
            text: message.into(),
            color: Some("#ef4444".to_string()),
            subtitle: None,
        }],
        icon_url: plugin.icon_data_url.clone(),
    }
}

fn persist_overlay_back_to_cache(
    plugin_id: &str,
    app_data_dir: &PathBuf,
    prepared: &PreparedCredentialOverlay,
    cache: &Arc<Mutex<HashMap<String, String>>>,
) {
    let Some(cache_key) = prepared.cache_key.as_ref() else {
        return;
    };

    let target_paths = credential_target_paths(plugin_id, app_data_dir);
    if target_paths.is_empty() {
        return;
    }

    let latest = {
        let Ok(overlay_locked) = prepared.overlay.lock() else {
            return;
        };

        let mut found: Option<String> = None;
        for path in &target_paths {
            let expanded = expand_path(path);
            if let Some(value) = overlay_locked
                .get(&expanded)
                .or_else(|| overlay_locked.get(path))
            {
                found = Some(value.clone());
                break;
            }
        }
        found
    };

    let Some(latest) = latest else {
        return;
    };

    if let Ok(mut cache_locked) = cache.lock() {
        cache_locked.insert(cache_key.clone(), latest);
    }
}

#[tauri::command]
fn init_panel(app_handle: tauri::AppHandle) {
    panel::init(&app_handle).expect("Failed to initialize panel");
}

#[tauri::command]
fn hide_panel(app_handle: tauri::AppHandle) {
    use tauri_nspanel::ManagerExt;
    if let Ok(panel) = app_handle.get_webview_panel("main") {
        panel.hide();
    }
}

#[tauri::command]
async fn start_probe_batch(
    app_handle: tauri::AppHandle,
    state: tauri::State<'_, Mutex<AppState>>,
    batch_id: Option<String>,
    plugin_ids: Option<Vec<String>>,
    account_selections: Option<HashMap<String, String>>,
) -> Result<ProbeBatchStarted, String> {
    let batch_id = batch_id
        .and_then(|id| {
            let trimmed = id.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let (plugins, app_data_dir, app_version, cliproxy_credential_cache) = {
        let locked = state.lock().map_err(|e| e.to_string())?;
        (
            locked.plugins.clone(),
            locked.app_data_dir.clone(),
            locked.app_version.clone(),
            locked.cliproxy_credential_cache.clone(),
        )
    };

    let selected_plugins = match plugin_ids {
        Some(ids) => {
            let mut by_id: HashMap<String, plugin_engine::manifest::LoadedPlugin> = plugins
                .into_iter()
                .map(|plugin| (plugin.manifest.id.clone(), plugin))
                .collect();
            let mut seen = HashSet::new();
            ids.into_iter()
                .filter_map(|id| {
                    if !seen.insert(id.clone()) {
                        return None;
                    }
                    by_id.remove(&id)
                })
                .collect()
        }
        None => plugins,
    };

    let response_plugin_ids: Vec<String> = selected_plugins
        .iter()
        .map(|plugin| plugin.manifest.id.clone())
        .collect();

    log::info!(
        "probe batch {} starting: {:?}",
        batch_id,
        response_plugin_ids
    );

    if selected_plugins.is_empty() {
        let _ = app_handle.emit(
            "probe:batch-complete",
            ProbeBatchComplete {
                batch_id: batch_id.clone(),
            },
        );
        return Ok(ProbeBatchStarted {
            batch_id,
            plugin_ids: response_plugin_ids,
        });
    }

    let mut prepared_overlays: HashMap<String, PreparedCredentialOverlay> = HashMap::new();
    let mut overlay_errors: HashMap<String, String> = HashMap::new();
    if let Some(selections) = account_selections.as_ref() {
        if !selections.is_empty() {
            match cliproxyapi::load_config() {
                Ok(Some(config)) => match cliproxyapi::list_auth_files_with_config(&config) {
                    Ok(auth_files) => {
                        for plugin in &selected_plugins {
                            let plugin_id = plugin.manifest.id.as_str();
                            let Some(selection) = selections.get(plugin_id) else {
                                continue;
                            };

                            if let Some(prepared) = prepare_credential_overlay(
                                plugin_id,
                                selection,
                                &app_data_dir,
                                &config,
                                &auth_files,
                                &cliproxy_credential_cache,
                            ) {
                                prepared_overlays.insert(plugin_id.to_string(), prepared);
                            } else {
                                overlay_errors.insert(
                                    plugin_id.to_string(),
                                    "Failed to load selected CLIProxy account. Verify selection and credentials."
                                        .to_string(),
                                );
                            }
                        }
                    }
                    Err(err) => {
                        log::warn!("CLIProxyAPI auth-files fetch failed: {}", err);
                        for plugin in &selected_plugins {
                            let plugin_id = plugin.manifest.id.as_str();
                            if selections.contains_key(plugin_id) {
                                overlay_errors.insert(
                                    plugin_id.to_string(),
                                    "Failed to load CLIProxy account list. Check CLIProxyAPI connection."
                                        .to_string(),
                                );
                            }
                        }
                    }
                },
                Ok(None) => {
                    for plugin in &selected_plugins {
                        let plugin_id = plugin.manifest.id.as_str();
                        if selections.contains_key(plugin_id) {
                            overlay_errors.insert(
                                plugin_id.to_string(),
                                "CLIProxyAPI is not configured. Select Local account or configure CLIProxyAPI."
                                    .to_string(),
                            );
                        }
                    }
                }
                Err(err) => {
                    log::warn!("CLIProxyAPI config read failed: {}", err);
                    for plugin in &selected_plugins {
                        let plugin_id = plugin.manifest.id.as_str();
                        if selections.contains_key(plugin_id) {
                            overlay_errors.insert(
                                plugin_id.to_string(),
                                "Failed to read CLIProxyAPI config. Select Local account or reconfigure CLIProxyAPI."
                                    .to_string(),
                            );
                        }
                    }
                }
            }
        }
    }

    let remaining = Arc::new(AtomicUsize::new(selected_plugins.len()));
    for plugin in selected_plugins {
        let handle = app_handle.clone();
        let completion_handle = app_handle.clone();
        let bid = batch_id.clone();
        let completion_bid = batch_id.clone();
        let data_dir = app_data_dir.clone();
        let version = app_version.clone();
        let counter = Arc::clone(&remaining);
        let prepared_overlay = prepared_overlays.get(&plugin.manifest.id).cloned();
        let overlay_error = overlay_errors.get(&plugin.manifest.id).cloned();
        let overlay_cache = cliproxy_credential_cache.clone();

        tauri::async_runtime::spawn_blocking(move || {
            let plugin_id = plugin.manifest.id.clone();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                if let Some(message) = overlay_error.clone() {
                    return plugin_error_output(&plugin, message);
                }

                let options = plugin_engine::runtime::RunProbeOptions {
                    credential_overlay: prepared_overlay
                        .as_ref()
                        .map(|prepared| prepared.overlay.clone()),
                };
                plugin_engine::runtime::run_probe(&plugin, &data_dir, &version, options)
            }));

            if let Some(prepared) = prepared_overlay.as_ref() {
                persist_overlay_back_to_cache(&plugin_id, &data_dir, prepared, &overlay_cache);
            }

            match result {
                Ok(output) => {
                    let has_error = output.lines.iter().any(|line| {
                        matches!(line, plugin_engine::runtime::MetricLine::Badge { label, .. } if label == "Error")
                    });
                    if has_error {
                        log::warn!("probe {} completed with error", plugin_id);
                    } else {
                        log::info!(
                            "probe {} completed ok ({} lines)",
                            plugin_id,
                            output.lines.len()
                        );
                    }
                    let _ = handle.emit(
                        "probe:result",
                        ProbeResult {
                            batch_id: bid,
                            output,
                        },
                    );
                }
                Err(_) => {
                    log::error!("probe {} panicked", plugin_id);
                }
            }

            if counter.fetch_sub(1, Ordering::SeqCst) == 1 {
                log::info!("probe batch {} complete", completion_bid);
                let _ = completion_handle.emit(
                    "probe:batch-complete",
                    ProbeBatchComplete {
                        batch_id: completion_bid,
                    },
                );
            }
        });
    }

    Ok(ProbeBatchStarted {
        batch_id,
        plugin_ids: response_plugin_ids,
    })
}

#[tauri::command]
fn get_log_path(app_handle: tauri::AppHandle) -> Result<String, String> {
    // macOS log directory: ~/Library/Logs/{bundleIdentifier}
    let home = dirs::home_dir().ok_or("no home dir")?;
    let bundle_id = app_handle.config().identifier.clone();
    let log_dir = home.join("Library").join("Logs").join(&bundle_id);
    let log_file = log_dir.join(format!("{}.log", app_handle.package_info().name));
    Ok(log_file.to_string_lossy().to_string())
}

#[tauri::command]
fn cliproxyapi_get_status() -> cliproxyapi::CliProxyConfigStatus {
    cliproxyapi::get_status()
}

#[tauri::command]
fn cliproxyapi_get_config() -> Result<cliproxyapi::CliProxyConfigView, String> {
    cliproxyapi::get_config_view()
}

#[tauri::command]
fn cliproxyapi_set_config(base_url: String, api_key: String) -> Result<(), String> {
    cliproxyapi::set_config(base_url, api_key)
}

#[tauri::command]
fn cliproxyapi_clear_config() -> Result<(), String> {
    cliproxyapi::clear_config()
}

#[tauri::command]
fn cliproxyapi_list_auth_files() -> Result<Vec<cliproxyapi::CliProxyAuthFile>, String> {
    cliproxyapi::list_auth_files()
}

/// Update the global shortcut registration.
/// Pass `null` to disable the shortcut, or a shortcut string like "CommandOrControl+Shift+U".
#[cfg(desktop)]
#[tauri::command]
fn update_global_shortcut(
    app_handle: tauri::AppHandle,
    shortcut: Option<String>,
) -> Result<(), String> {
    let global_shortcut = app_handle.global_shortcut();
    let normalized_shortcut = shortcut.and_then(|value| {
        let trimmed = value.trim().to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    });
    let mut managed_shortcut = managed_shortcut_slot()
        .lock()
        .map_err(|e| format!("failed to lock managed shortcut state: {}", e))?;

    if *managed_shortcut == normalized_shortcut {
        log::debug!("Global shortcut unchanged");
        return Ok(());
    }

    let previous_shortcut = managed_shortcut.clone();
    if let Some(existing) = previous_shortcut.as_deref() {
        match global_shortcut.unregister(existing) {
            Ok(()) => {
                // Keep in-memory state aligned with actual registration state.
                *managed_shortcut = None;
            }
            Err(e) => {
                log::warn!(
                    "Failed to unregister existing shortcut '{}': {}",
                    existing,
                    e
                );
            }
        }
    }

    if let Some(shortcut) = normalized_shortcut {
        log::info!("Registering global shortcut: {}", shortcut);
        global_shortcut
            .on_shortcut(shortcut.as_str(), |app, _shortcut, event| {
                handle_global_shortcut(app, event);
            })
            .map_err(|e| format!("Failed to register shortcut '{}': {}", shortcut, e))?;
        *managed_shortcut = Some(shortcut);
    } else {
        log::info!("Global shortcut disabled");
        *managed_shortcut = None;
    }

    Ok(())
}

#[tauri::command]
fn list_plugins(state: tauri::State<'_, Mutex<AppState>>) -> Vec<PluginMeta> {
    let plugins = {
        let locked = state.lock().expect("plugin state poisoned");
        locked.plugins.clone()
    };
    log::debug!("list_plugins: {} plugins", plugins.len());

    plugins
        .into_iter()
        .map(|plugin| {
            // Extract primary candidates: progress lines with primary_order, sorted by order
            let mut candidates: Vec<_> = plugin
                .manifest
                .lines
                .iter()
                .filter(|line| line.line_type == "progress" && line.primary_order.is_some())
                .collect();
            candidates.sort_by_key(|line| line.primary_order.unwrap());
            let primary_candidates: Vec<String> =
                candidates.iter().map(|line| line.label.clone()).collect();

            PluginMeta {
                id: plugin.manifest.id,
                name: plugin.manifest.name,
                icon_url: plugin.icon_data_url,
                brand_color: plugin.manifest.brand_color,
                lines: plugin
                    .manifest
                    .lines
                    .iter()
                    .map(|line| ManifestLineDto {
                        line_type: line.line_type.clone(),
                        label: line.label.clone(),
                        scope: line.scope.clone(),
                    })
                    .collect(),
                links: plugin
                    .manifest
                    .links
                    .iter()
                    .map(|link| PluginLinkDto {
                        label: link.label.clone(),
                        url: link.url.clone(),
                    })
                    .collect(),
                primary_candidates,
            }
        })
        .collect()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let runtime = tokio::runtime::Runtime::new().expect("Failed to create Tokio runtime");
    let _guard = runtime.enter();

    tauri::Builder::default()
        .plugin(tauri_plugin_aptabase::Builder::new("A-US-6435241436").build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_nspanel::init())
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    Target::new(TargetKind::Stdout),
                    Target::new(TargetKind::LogDir { file_name: None }),
                ])
                .max_file_size(10_000_000) // 10 MB
                .level(log::LevelFilter::Trace) // Allow all levels; runtime filter via tray menu
                .level_for("hyper", log::LevelFilter::Warn)
                .level_for("reqwest", log::LevelFilter::Warn)
                .level_for("tao", log::LevelFilter::Info)
                .level_for("tauri_plugin_updater", log::LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_autostart::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            init_panel,
            hide_panel,
            start_probe_batch,
            list_plugins,
            get_log_path,
            cliproxyapi_get_status,
            cliproxyapi_get_config,
            cliproxyapi_set_config,
            cliproxyapi_clear_config,
            cliproxyapi_list_auth_files,
            update_global_shortcut
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            #[cfg(target_os = "macos")]
            {
                app_nap::disable_app_nap();
                webkit_config::disable_webview_suspension(app.handle());
            }

            use tauri::Manager;

            let version = app.package_info().version.to_string();
            log::info!("OpenUsage v{} starting", version);

            track_app_started_once_per_day_per_version(app);

            let app_data_dir = app.path().app_data_dir().expect("no app data dir");
            let resource_dir = app.path().resource_dir().expect("no resource dir");
            log::debug!("app_data_dir: {:?}", app_data_dir);

            let (_, plugins) = plugin_engine::initialize_plugins(&app_data_dir, &resource_dir);
            app.manage(Mutex::new(AppState {
                plugins,
                app_data_dir,
                app_version: app.package_info().version.to_string(),
                cliproxy_credential_cache: Arc::new(Mutex::new(HashMap::new())),
            }));

            tray::create(app.handle())?;

            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;

            // Register global shortcut from stored settings
            #[cfg(desktop)]
            {
                use tauri_plugin_store::StoreExt;

                if let Ok(store) = app.handle().store("settings.json") {
                    if let Some(shortcut_value) = store.get(GLOBAL_SHORTCUT_STORE_KEY) {
                        if let Some(shortcut) = shortcut_value.as_str() {
                            let shortcut = shortcut.trim();
                            if !shortcut.is_empty() {
                                let handle = app.handle().clone();
                                log::info!("Registering initial global shortcut: {}", shortcut);
                                if let Err(e) = handle.global_shortcut().on_shortcut(
                                    shortcut,
                                    |app, _shortcut, event| {
                                        handle_global_shortcut(app, event);
                                    },
                                ) {
                                    log::warn!("Failed to register initial global shortcut: {}", e);
                                } else if let Ok(mut managed_shortcut) =
                                    managed_shortcut_slot().lock()
                                {
                                    *managed_shortcut = Some(shortcut.to_string());
                                } else {
                                    log::warn!("Failed to store managed shortcut in memory");
                                }
                            }
                        }
                    }
                }
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_, _| {});
}

#[cfg(test)]
mod tests {
    use super::{
        app_started_day_key, should_track_app_started, should_use_cached_overlay,
        transform_auth_payload_for_plugin,
    };

    #[test]
    fn should_track_when_no_previous_day() {
        assert!(should_track_app_started(None, "2026-02-12"));
    }

    #[test]
    fn should_not_track_when_same_day() {
        assert!(!should_track_app_started(Some("2026-02-12"), "2026-02-12"));
    }

    #[test]
    fn should_track_when_day_changes() {
        assert!(should_track_app_started(Some("2026-02-11"), "2026-02-12"));
    }

    #[test]
    fn key_is_version_scoped() {
        let v1_key = app_started_day_key("0.6.2");
        let v2_key = app_started_day_key("0.6.3");
        assert_ne!(v1_key, v2_key);
        assert!(v1_key.ends_with("0.6.2"));
        assert!(v2_key.ends_with("0.6.3"));
    }

    #[test]
    fn antigravity_cached_overlay_rejected_when_expired() {
        let payload = r#"{"accessToken":"x","expiresAtMs":1}"#;
        assert!(!should_use_cached_overlay("antigravity", payload));
    }

    #[test]
    fn antigravity_cached_overlay_rejected_when_invalid() {
        assert!(!should_use_cached_overlay("antigravity", "{bad json"));
    }

    #[test]
    fn antigravity_cached_overlay_used_when_fresh() {
        let now_raw = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
        let now_ms = i64::try_from(now_raw).unwrap_or(0);
        let payload = format!(
            r#"{{"accessToken":"x","expiresAtMs":{}}}"#,
            now_ms + 5 * 60_000
        );
        assert!(should_use_cached_overlay("antigravity", &payload));
    }

    #[test]
    fn gemini_cached_overlay_rejected_when_expired() {
        let payload = r#"{"access_token":"x","expiry_date":1}"#;
        assert!(!should_use_cached_overlay("gemini", payload));
    }

    #[test]
    fn gemini_cached_overlay_used_when_future_seconds_epoch() {
        let now_raw = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
        let now_ms = i64::try_from(now_raw).unwrap_or(0);
        let future_seconds = (now_ms / 1000) + 600;
        let payload = format!(r#"{{"access_token":"x","expiry_date":{}}}"#, future_seconds);
        assert!(should_use_cached_overlay("gemini", &payload));
    }

    #[test]
    fn gemini_cached_overlay_rejected_when_invalid() {
        assert!(!should_use_cached_overlay("gemini", "{bad json"));
    }

    #[test]
    fn gemini_transform_supports_nested_token_payloads() {
        let raw = r#"{
            "type": "gemini-cli",
            "token": {
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "client_id": "client-1",
                "client_secret": "secret-1",
                "expiry": "2099-01-01T00:00:00Z"
            }
        }"#;

        let transformed =
            transform_auth_payload_for_plugin("gemini", raw).expect("gemini transform succeeds");
        let value: serde_json::Value =
            serde_json::from_str(&transformed).expect("transformed payload parses");
        let object = value.as_object().expect("transformed payload object");

        assert_eq!(object.get("access_token").and_then(|v| v.as_str()), Some("access-1"));
        assert_eq!(object.get("refresh_token").and_then(|v| v.as_str()), Some("refresh-1"));
        assert_eq!(object.get("client_id").and_then(|v| v.as_str()), Some("client-1"));
        assert_eq!(
            object.get("client_secret").and_then(|v| v.as_str()),
            Some("secret-1")
        );
        assert!(
            object
                .get("expiry_date")
                .and_then(|v| v.as_i64())
                .unwrap_or_default()
                > 4_000_000_000_000
        );
    }

    #[test]
    fn non_antigravity_cached_overlay_is_unchanged() {
        assert!(should_use_cached_overlay("codex", "{bad json"));
    }
}
