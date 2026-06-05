use super::ledger::append_ledger_entry;
use super::metering::{extract_usage_from_json, extract_usage_from_sse, price_usage};
use super::secrets::{read_local_token, read_upstream_key};
use super::types::{LedgerEntry, OpenAiCompatibleSettings};
use super::{SETTINGS_FILE_NAME, SETTINGS_KEY};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

const BIND_ADDR: &str = "127.0.0.1:6737";

pub fn start_server(app_data_dir: PathBuf) {
    std::thread::spawn(move || {
        let listener = match TcpListener::bind(BIND_ADDR) {
            Ok(listener) => listener,
            Err(error) => {
                log::warn!(
                    "failed to bind OpenAI-compatible proxy on {}: {}",
                    BIND_ADDR,
                    error
                );
                return;
            }
        };
        log::info!("OpenAI-compatible proxy listening on {}", BIND_ADDR);
        for stream in listener.incoming() {
            if let Ok(stream) = stream {
                let data_dir = app_data_dir.clone();
                std::thread::spawn(move || handle_connection(stream, data_dir));
            }
        }
    });
}

pub fn load_settings(app_data_dir: &Path) -> Option<OpenAiCompatibleSettings> {
    let text = std::fs::read_to_string(app_data_dir.join(SETTINGS_FILE_NAME)).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let raw = value.get(SETTINGS_KEY)?;
    serde_json::from_value(raw.clone()).ok()
}

fn handle_connection(mut stream: TcpStream, app_data_dir: PathBuf) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));

    let mut buf = Vec::new();
    let mut chunk = [0_u8; 4096];
    loop {
        let Ok(n) = stream.read(&mut chunk) else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some((header_end, content_length)) = request_header_info(&buf) {
            while buf.len() < header_end + content_length {
                let Ok(n) = stream.read(&mut chunk) else { return };
                if n == 0 {
                    return;
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            break;
        }
        if buf.len() > 128 * 1024 {
            let _ = stream.write_all(response_text(413, "Payload Too Large", "payload too large").as_bytes());
            return;
        }
    }

    let response = handle_request_bytes(&app_data_dir, &buf);
    let _ = stream.write_all(&response);
}

fn handle_request_bytes(app_data_dir: &Path, bytes: &[u8]) -> Vec<u8> {
    let Some(request) = parse_request(bytes) else {
        return response_text(400, "Bad Request", "bad request").into_bytes();
    };
    if request.method != "POST"
        || (request.path != "/v1/chat/completions" && request.path != "/v1/responses")
    {
        return response_text(404, "Not Found", "not found").into_bytes();
    }

    let Some(settings) = load_settings(app_data_dir).filter(|settings| settings.enabled) else {
        return response_text(503, "Service Unavailable", "proxy not configured").into_bytes();
    };
    let Some(local_token) = read_local_token() else {
        return response_text(503, "Service Unavailable", "local token not configured").into_bytes();
    };
    let Some(upstream_key) = read_upstream_key() else {
        return response_text(503, "Service Unavailable", "upstream key not configured").into_bytes();
    };
    if !authorization_matches(&request.headers, &local_token) {
        return response_text(401, "Unauthorized", "unauthorized").into_bytes();
    }

    forward_request(app_data_dir, request, &settings, &upstream_key)
}

fn forward_request(
    app_data_dir: &Path,
    request: ParsedRequest,
    settings: &OpenAiCompatibleSettings,
    upstream_key: &str,
) -> Vec<u8> {
    let model = request_model(&request.body).unwrap_or_else(|| "unknown".to_string());
    let upstream_url = format!(
        "{}/{}",
        settings.endpoint.trim_end_matches('/'),
        request.path.trim_start_matches('/')
    );

    let mut headers = reqwest::header::HeaderMap::new();
    for (key, value) in &request.headers {
        let key_lower = key.to_ascii_lowercase();
        if ["host", "content-length", "authorization", "connection"].contains(&key_lower.as_str()) {
            continue;
        }
        if let (Ok(name), Ok(value)) = (
            reqwest::header::HeaderName::from_bytes(key.as_bytes()),
            reqwest::header::HeaderValue::from_str(value),
        ) {
            headers.insert(name, value);
        }
    }
    headers.insert(
        reqwest::header::AUTHORIZATION,
        reqwest::header::HeaderValue::from_str(&format!("Bearer {}", upstream_key))
            .unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("Bearer invalid")),
    );

    let mut client_builder = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none());
    if let Some(resolved) = crate::config::get_resolved_proxy() {
        client_builder = client_builder.proxy(resolved.proxy.clone());
    }
    let client = match client_builder.build() {
        Ok(client) => client,
        Err(error) => return response_text(502, "Bad Gateway", &error.to_string()).into_bytes(),
    };
    let response = match client.post(&upstream_url).headers(headers).body(request.body).send() {
        Ok(response) => response,
        Err(error) => return response_text(502, "Bad Gateway", &error.to_string()).into_bytes(),
    };

    let status = response.status().as_u16();
    let reason = response.status().canonical_reason().unwrap_or("OK").to_string();
    let response_headers = response
        .headers()
        .iter()
        .filter_map(|(key, value)| {
            let key_lower = key.as_str().to_ascii_lowercase();
            if key_lower == "content-length" || key_lower == "connection" {
                return None;
            }
            Some((key.as_str().to_string(), value.to_str().ok()?.to_string()))
        })
        .collect::<Vec<_>>();
    let body = match response.bytes() {
        Ok(body) => body.to_vec(),
        Err(error) => return response_text(502, "Bad Gateway", &error.to_string()).into_bytes(),
    };

    if (200..300).contains(&status) {
        record_success(app_data_dir, &model, &body, &settings.prices);
    }

    response_bytes(status, &reason, response_headers, &body)
}

fn record_success(
    app_data_dir: &Path,
    model: &str,
    body: &[u8],
    prices: &[super::types::ModelPrice],
) {
    let body_text = String::from_utf8_lossy(body);
    let usage = if body_text.contains("\ndata:") || body_text.trim_start().starts_with("data:") {
        extract_usage_from_sse(&body_text)
    } else {
        extract_usage_from_json(&body_text)
    };
    if let Some(usage) = usage {
        let priced = price_usage(model, usage, prices);
        append_ledger_entry(
            app_data_dir,
            LedgerEntry {
                fetched_at: now_iso(),
                model: model.to_string(),
                input_tokens: priced.input_tokens,
                output_tokens: priced.output_tokens,
                cost_usd: priced.cost_usd,
                unpriced: priced.unpriced,
                unmetered: false,
            },
        );
    } else {
        append_ledger_entry(app_data_dir, LedgerEntry::unmetered(&now_iso(), model));
    }
}

fn request_model(body: &[u8]) -> Option<String> {
    let value: Value = serde_json::from_slice(body).ok()?;
    value.get("model")?.as_str().map(|model| model.to_string())
}

fn now_iso() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

fn authorization_matches(headers: &HashMap<String, String>, token: &str) -> bool {
    headers
        .get("authorization")
        .map(|value| value.trim() == format!("Bearer {}", token))
        .unwrap_or(false)
}

struct ParsedRequest {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

fn parse_request(bytes: &[u8]) -> Option<ParsedRequest> {
    let header_end = bytes.windows(4).position(|window| window == b"\r\n\r\n")? + 4;
    let header_text = String::from_utf8_lossy(&bytes[..header_end]);
    let mut lines = header_text.lines();
    let mut first_parts = lines.next()?.split_whitespace();
    let method = first_parts.next()?.to_string();
    let path = first_parts.next()?.split('?').next()?.to_string();
    let mut headers = HashMap::new();
    for line in lines {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
    }
    Some(ParsedRequest {
        method,
        path,
        headers,
        body: bytes[header_end..].to_vec(),
    })
}

fn request_header_info(bytes: &[u8]) -> Option<(usize, usize)> {
    let header_end = bytes.windows(4).position(|window| window == b"\r\n\r\n")? + 4;
    let header_text = String::from_utf8_lossy(&bytes[..header_end]);
    let content_length = header_text
        .lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(key, _)| key.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    Some((header_end, content_length))
}

fn response_text(status: u16, reason: &str, text: &str) -> String {
    format!(
        "HTTP/1.1 {} {}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\r\n{}",
        status,
        reason,
        text.len(),
        text
    )
}

fn response_bytes(
    status: u16,
    reason: &str,
    headers: Vec<(String, String)>,
    body: &[u8],
) -> Vec<u8> {
    let mut out = format!("HTTP/1.1 {} {}\r\nConnection: close\r\n", status, reason);
    for (key, value) in headers {
        out.push_str(&format!("{}: {}\r\n", key, value));
    }
    out.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
    let mut bytes = out.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openai_proxy::ledger::load_ledger;
    use crate::openai_proxy::types::ModelPrice;

    #[test]
    fn local_token_auth_requires_exact_bearer_token() {
        let mut headers = HashMap::new();
        headers.insert("authorization".to_string(), "Bearer local-token".to_string());

        assert!(authorization_matches(&headers, "local-token"));
        assert!(!authorization_matches(&headers, "wrong-token"));

        headers.insert("authorization".to_string(), "local-token".to_string());
        assert!(!authorization_matches(&headers, "local-token"));
    }

    #[test]
    fn record_success_persists_responses_usage_with_price() {
        let app_data_dir = std::env::temp_dir().join(format!(
            "openusage-openai-proxy-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&app_data_dir).expect("temp app data dir");
        let body = br#"{"usage":{"input_tokens":1000,"output_tokens":2000}}"#;
        let prices = vec![ModelPrice {
            model_name: "test-model".to_string(),
            input_usd_per_1m: 1.0,
            output_usd_per_1m: 2.0,
        }];

        record_success(&app_data_dir, "test-model", body, &prices);

        let entries = load_ledger(&app_data_dir);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].model, "test-model");
        assert_eq!(entries[0].input_tokens, 1000);
        assert_eq!(entries[0].output_tokens, 2000);
        assert_eq!(entries[0].cost_usd, Some(0.005));
        assert!(!entries[0].unmetered);
    }

    #[test]
    fn record_success_marks_missing_usage_unmetered() {
        let app_data_dir = std::env::temp_dir().join(format!(
            "openusage-openai-proxy-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&app_data_dir).expect("temp app data dir");

        record_success(&app_data_dir, "test-model", br#"{"id":"ok"}"#, &[]);

        let entries = load_ledger(&app_data_dir);
        assert_eq!(entries.len(), 1);
        assert!(entries[0].unmetered);
        assert_eq!(entries[0].cost_usd, None);
    }
}
