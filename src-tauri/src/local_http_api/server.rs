use super::cache::{cache_state, enabled_snapshots_ordered};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

const BIND_ADDR: &str = "127.0.0.1:6736";

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
                Ok(stream) => {
                    std::thread::spawn(move || handle_connection(stream));
                }
                Err(e) => log::debug!("local HTTP API accept error: {}", e),
            }
        }
    });
}

fn handle_connection(mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(5)));

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
            "OPTIONS" => response_no_content(),
            _ => response_method_not_allowed(),
        };
    }

    if let Some(provider_id) = path.strip_prefix("/v1/usage/") {
        if !provider_id.is_empty() && !provider_id.contains('/') {
            return match method {
                "GET" => handle_get_usage_single(provider_id),
                "OPTIONS" => response_no_content(),
                _ => response_method_not_allowed(),
            };
        }
    }

    response_not_found("not_found")
}

fn handle_get_usage_collection() -> String {
    let snapshots = {
        let state = cache_state().lock().expect("cache state poisoned");
        enabled_snapshots_ordered(&state)
    };
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
        "HTTP/1.1 {} {}\r\nConnection: close\r\nContent-Type: application/json; charset=utf-8\r\n{}\r\nContent-Length: {}\r\n\r\n{}",
        status,
        reason,
        CORS_HEADERS,
        body.len(),
        body,
    )
}

fn response_no_content() -> String {
    format!(
        "HTTP/1.1 204 No Content\r\nConnection: close\r\n{}\r\n\r\n",
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
    use super::super::cache::{cache_state, CachedPluginSnapshot};
    use super::*;
    use serial_test::serial;

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
    #[serial]
    fn route_unknown_provider_returns_404() {
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
    #[serial]
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
    #[serial]
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
}
