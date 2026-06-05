use super::{KEYCHAIN_LOCAL_TOKEN_SERVICE, KEYCHAIN_UPSTREAM_SERVICE};
use super::types::OpenAiProxySecretStatus;
use std::process::Command;
use uuid::Uuid;

pub fn get_openai_proxy_secret_status() -> Result<OpenAiProxySecretStatus, String> {
    Ok(OpenAiProxySecretStatus {
        has_upstream_key: read_secret(KEYCHAIN_UPSTREAM_SERVICE).is_some(),
        has_local_token: read_secret(KEYCHAIN_LOCAL_TOKEN_SERVICE).is_some(),
    })
}

pub fn save_openai_proxy_upstream_key(value: String) -> Result<OpenAiProxySecretStatus, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("Upstream key cannot be empty".to_string());
    }
    write_secret(KEYCHAIN_UPSTREAM_SERVICE, trimmed)?;
    get_openai_proxy_secret_status()
}

pub fn get_openai_proxy_local_token() -> Result<String, String> {
    if let Some(token) = read_secret(KEYCHAIN_LOCAL_TOKEN_SERVICE) {
        return Ok(token);
    }
    regenerate_openai_proxy_local_token()
}

pub fn regenerate_openai_proxy_local_token() -> Result<String, String> {
    let token = format!("ou_{}", Uuid::new_v4().simple());
    write_secret(KEYCHAIN_LOCAL_TOKEN_SERVICE, &token)?;
    Ok(token)
}

pub fn read_upstream_key() -> Option<String> {
    read_secret(KEYCHAIN_UPSTREAM_SERVICE)
}

pub fn read_local_token() -> Option<String> {
    read_secret(KEYCHAIN_LOCAL_TOKEN_SERVICE)
}

fn read_secret(service: &str) -> Option<String> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", service, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn write_secret(service: &str, value: &str) -> Result<(), String> {
    let output = Command::new("security")
        .args(["add-generic-password", "-U", "-s", service, "-w", value])
        .output()
        .map_err(|e| format!("keychain write failed: {}", e))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("keychain write failed: {}", stderr.trim()))
    }
}
