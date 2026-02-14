use serde::{Deserialize, Serialize};
use serde_json::Value;

const CLIPROXY_KEYCHAIN_SERVICE: &str = "OpenUsage-CLIProxyAPI";
const CLIPROXY_KEYCHAIN_ACCOUNT: &str = "config";

#[derive(Debug, Clone)]
pub struct CliProxyConfig {
    pub base_url: String,
    pub api_key: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyConfigStatus {
    pub configured: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyConfigView {
    pub configured: bool,
    pub base_url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyAuthFile {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub email: Option<String>,
    pub auth_index: Option<String>,
    pub disabled: bool,
    pub unavailable: bool,
    pub runtime_only: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredConfig {
    #[serde(alias = "base_url")]
    base_url: String,
    #[serde(alias = "api_key")]
    api_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedConfig<'a> {
    base_url: &'a str,
    api_key: &'a str,
}

pub fn get_status() -> CliProxyConfigStatus {
    let configured = load_config().ok().flatten().is_some();
    CliProxyConfigStatus { configured }
}

pub fn get_config_view() -> Result<CliProxyConfigView, String> {
    let config = load_config()?;
    Ok(match config {
        Some(c) => CliProxyConfigView {
            configured: true,
            base_url: Some(c.base_url),
        },
        None => CliProxyConfigView {
            configured: false,
            base_url: None,
        },
    })
}

pub fn set_config(base_url: String, api_key: String) -> Result<(), String> {
    let normalized_base_url = normalize_base_url(&base_url)?;
    let trimmed_api_key = api_key.trim();
    if trimmed_api_key.is_empty() {
        return Err("management key is required".to_string());
    }

    let payload = PersistedConfig {
        base_url: &normalized_base_url,
        api_key: trimmed_api_key,
    };
    let raw =
        serde_json::to_string(&payload).map_err(|e| format!("failed to encode config: {}", e))?;
    write_keychain(CLIPROXY_KEYCHAIN_SERVICE, CLIPROXY_KEYCHAIN_ACCOUNT, &raw)
}

pub fn clear_config() -> Result<(), String> {
    delete_keychain(CLIPROXY_KEYCHAIN_SERVICE, CLIPROXY_KEYCHAIN_ACCOUNT)
}

pub fn load_config() -> Result<Option<CliProxyConfig>, String> {
    let Some(raw) = read_keychain(CLIPROXY_KEYCHAIN_SERVICE, CLIPROXY_KEYCHAIN_ACCOUNT)? else {
        return Ok(None);
    };

    let stored: StoredConfig = serde_json::from_str(&raw)
        .map_err(|e| format!("invalid CLIProxyAPI config in keychain: {}", e))?;

    let base_url = normalize_base_url(&stored.base_url)?;
    let api_key = stored.api_key.trim().to_string();
    if api_key.is_empty() {
        return Err("invalid CLIProxyAPI config in keychain: empty management key".to_string());
    }

    Ok(Some(CliProxyConfig { base_url, api_key }))
}

pub fn list_auth_files() -> Result<Vec<CliProxyAuthFile>, String> {
    let Some(config) = load_config()? else {
        return Ok(Vec::new());
    };
    list_auth_files_with_config(&config)
}

pub fn list_auth_files_with_config(
    config: &CliProxyConfig,
) -> Result<Vec<CliProxyAuthFile>, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("failed to create HTTP client: {}", e))?;

    let url = format!("{}/v0/management/auth-files", config.base_url);
    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", config.api_key))
        .send()
        .map_err(|e| format!("failed to fetch auth files: {}", e))?;

    let status = response.status().as_u16();
    let body = response
        .text()
        .map_err(|e| format!("failed to read auth-files response: {}", e))?;

    if status < 200 || status >= 300 {
        return Err(format!("auth-files request failed with HTTP {}", status));
    }

    parse_auth_files_response(&body)
}

pub fn download_auth_file_by_name(config: &CliProxyConfig, name: &str) -> Result<String, String> {
    let trimmed_name = name.trim();
    if trimmed_name.is_empty() {
        return Err("auth file name is required".to_string());
    }

    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("failed to create HTTP client: {}", e))?;

    let encoded_name = url_encode_component(trimmed_name);
    let url = format!(
        "{}/v0/management/auth-files/download?name={}",
        config.base_url, encoded_name
    );

    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", config.api_key))
        .send()
        .map_err(|e| format!("failed to download auth file '{}': {}", trimmed_name, e))?;

    let status = response.status().as_u16();
    let body = response
        .text()
        .map_err(|e| format!("failed to read auth file '{}': {}", trimmed_name, e))?;

    if status < 200 || status >= 300 {
        return Err(format!(
            "auth file download failed for '{}' with HTTP {}",
            trimmed_name, status
        ));
    }

    Ok(body)
}

fn parse_auth_files_response(body: &str) -> Result<Vec<CliProxyAuthFile>, String> {
    let parsed: Value = serde_json::from_str(body)
        .map_err(|e| format!("invalid auth-files response JSON: {}", e))?;

    let files_value = if let Some(arr) = parsed.as_array() {
        Value::Array(arr.clone())
    } else {
        parsed
            .get("files")
            .cloned()
            .ok_or_else(|| "auth-files response missing 'files'".to_string())?
    };

    let files = files_value
        .as_array()
        .ok_or_else(|| "auth-files response 'files' is not an array".to_string())?;

    let mut out = Vec::with_capacity(files.len());
    for entry in files {
        let Some(obj) = entry.as_object() else {
            continue;
        };

        let name = get_string(obj, &["name"]).unwrap_or_default();
        if name.trim().is_empty() {
            continue;
        }

        let provider = get_string(obj, &["provider", "type"])
            .unwrap_or_else(|| "unknown".to_string())
            .trim()
            .to_lowercase();
        let auth_index = get_string(obj, &["auth_index", "authIndex"]);
        let id = get_string(obj, &["id"])
            .or_else(|| auth_index.clone())
            .unwrap_or_else(|| name.clone());

        let email = get_string(obj, &["email", "account", "username"]);
        let disabled = get_bool(obj, &["disabled"]).unwrap_or(false);
        let unavailable = get_bool(obj, &["unavailable"]).unwrap_or(false);
        let runtime_only = get_bool(obj, &["runtime_only", "runtimeOnly"]).unwrap_or(false);

        out.push(CliProxyAuthFile {
            id,
            name,
            provider,
            email,
            auth_index,
            disabled,
            unavailable,
            runtime_only,
        });
    }

    Ok(out)
}

fn get_string(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        let Some(value) = map.get(*key) else {
            continue;
        };
        match value {
            Value::String(s) => {
                let trimmed = s.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
            Value::Number(n) => return Some(n.to_string()),
            Value::Bool(b) => return Some(b.to_string()),
            _ => {}
        }
    }
    None
}

fn get_bool(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<bool> {
    for key in keys {
        let Some(value) = map.get(*key) else {
            continue;
        };
        match value {
            Value::Bool(b) => return Some(*b),
            Value::String(s) => {
                let lower = s.trim().to_lowercase();
                if lower == "true" {
                    return Some(true);
                }
                if lower == "false" {
                    return Some(false);
                }
            }
            Value::Number(n) => {
                if let Some(v) = n.as_i64() {
                    return Some(v != 0);
                }
            }
            _ => {}
        }
    }
    None
}

fn normalize_base_url(base_url: &str) -> Result<String, String> {
    let mut normalized = base_url.trim().to_string();
    if normalized.is_empty() {
        return Err("management base URL is required".to_string());
    }

    normalized = normalized.trim_end_matches('/').to_string();
    let lower = normalized.to_lowercase();
    if lower.ends_with("/v0/management") {
        let keep_len = normalized.len() - "/v0/management".len();
        normalized = normalized[..keep_len].to_string();
    }

    if !normalized.starts_with("http://") && !normalized.starts_with("https://") {
        normalized = format!("http://{}", normalized);
    }

    normalized = normalized.trim_end_matches('/').to_string();
    if normalized.is_empty() {
        return Err("invalid management base URL".to_string());
    }

    Ok(normalized)
}

fn url_encode_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        if byte.is_ascii_alphanumeric()
            || *byte == b'-'
            || *byte == b'_'
            || *byte == b'.'
            || *byte == b'~'
        {
            out.push(*byte as char);
        } else {
            out.push('%');
            out.push_str(&format!("{:02X}", byte));
        }
    }
    out
}

fn read_keychain(service: &str, account: &str) -> Result<Option<String>, String> {
    if !cfg!(target_os = "macos") {
        return Ok(None);
    }

    let output = std::process::Command::new("security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .output()
        .map_err(|e| format!("keychain read failed: {}", e))?;

    if !output.status.success() {
        return Ok(None);
    }

    Ok(Some(
        String::from_utf8_lossy(&output.stdout).trim().to_string(),
    ))
}

fn write_keychain(service: &str, account: &str, value: &str) -> Result<(), String> {
    if !cfg!(target_os = "macos") {
        return Err("CLIProxyAPI config is only supported on macOS".to_string());
    }

    let output = std::process::Command::new("security")
        .args([
            "add-generic-password",
            "-s",
            service,
            "-a",
            account,
            "-w",
            value,
            "-U",
        ])
        .output()
        .map_err(|e| format!("keychain write failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.lines().next().unwrap_or("unknown error").trim();
        return Err(format!("keychain write failed: {}", detail));
    }

    Ok(())
}

fn delete_keychain(service: &str, account: &str) -> Result<(), String> {
    if !cfg!(target_os = "macos") {
        return Ok(());
    }

    let output = std::process::Command::new("security")
        .args(["delete-generic-password", "-s", service, "-a", account])
        .output()
        .map_err(|e| format!("keychain delete failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.lines().next().unwrap_or("").trim();
        if detail.contains("could not be found") || detail.contains("not found") {
            return Ok(());
        }
        return Err(format!("keychain delete failed: {}", detail));
    }

    Ok(())
}
