use reqwest::Proxy;
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::OnceLock;

/// Proxy configuration loaded from ~/.openusage/config.json
#[derive(Debug, Clone, Deserialize)]
pub struct ProxyConfig {
    pub enabled: bool,
    pub url: String,
}

/// Top-level application config
#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub proxy: Option<ProxyConfig>,
}

/// Resolved proxy state — computed once at startup, used per-request.
/// This avoids re-parsing or re-validating on every HTTP call.
#[derive(Debug, Clone)]
pub struct ResolvedProxy {
    pub proxy: Proxy,
}

/// Global resolved proxy: Some(active) or None(disabled).
static RESOLVED_PROXY: OnceLock<Option<ResolvedProxy>> = OnceLock::new();

/// Returns the resolved proxy, or None if disabled/invalid/missing.
/// Loaded once from disk on first call; subsequent calls are zero-cost.
pub fn get_resolved_proxy() -> Option<&'static ResolvedProxy> {
    RESOLVED_PROXY.get_or_init(|| load_and_resolve_proxy()).as_ref()
}

/// Config file path: ~/.openusage/config.json
fn config_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".openusage").join("config.json"))
}

/// Loads config from disk, resolves proxy, logs result.
fn load_and_resolve_proxy() -> Option<ResolvedProxy> {
    let Some(path) = config_path() else {
        log::debug!("[config] no home directory, proxy disabled");
        return None;
    };
    let config = match std::fs::read_to_string(&path) {
        Ok(contents) => match serde_json::from_str::<AppConfig>(&contents) {
            Ok(cfg) => cfg,
            Err(e) => {
                log::warn!("[config] failed to parse {}: {}, using defaults", path.display(), e);
                return None;
            }
        },
        Err(_) => {
            log::debug!("[config] no config file at {}, using defaults", path.display());
            return None;
        }
    };

    let Some(proxy_cfg) = config.proxy.as_ref().filter(|p| p.enabled) else {
        log::debug!("[config] proxy disabled");
        return None;
    };

    match Proxy::all(&proxy_cfg.url) {
        Ok(proxy) => {
            let redacted = redact_proxy_url(&proxy_cfg.url);
            log::debug!("[config] proxy enabled: {}", redacted);

            // Build no-proxy bypass for localhost
            let no_proxy = reqwest::NoProxy::from_string("localhost,127.0.0.1,::1");
            let proxy = proxy.no_proxy(no_proxy);

            Some(ResolvedProxy { proxy })
        }
        Err(e) => {
            log::warn!("[config] proxy disabled due to invalid URL: {}", e);
            None
        }
    }
}

/// Redacts user info from a proxy URL for safe logging.
pub fn redact_proxy_url(url: &str) -> String {
    // Simple redaction: look for ://user:pass@ pattern
    if let Some(at_pos) = url.find('@') {
        if let Some(scheme_end) = url.find("://") {
            let userinfo_start = scheme_end + 3;
            format!("{}***@{}", &url[..userinfo_start], &url[at_pos + 1..])
        } else {
            format!("***@{}", &url[at_pos + 1..])
        }
    } else {
        url.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redact_proxy_url_with_credentials() {
        let url = "http://user:pass@127.0.0.1:10808";
        let redacted = redact_proxy_url(url);
        assert_eq!(redacted, "http://***@127.0.0.1:10808");
        assert!(!redacted.contains("user"));
        assert!(!redacted.contains("pass"));
    }

    #[test]
    fn redact_proxy_url_without_credentials() {
        let url = "http://127.0.0.1:10808";
        let redacted = redact_proxy_url(url);
        assert_eq!(redacted, "http://127.0.0.1:10808");
    }

    #[test]
    fn proxy_disabled_when_enabled_false() {
        let config = AppConfig {
            proxy: Some(ProxyConfig {
                enabled: false,
                url: "http://127.0.0.1:10808".to_string(),
            }),
        };
        assert!(config.proxy.as_ref().filter(|p| p.enabled).is_none());
    }

    #[test]
    fn proxy_enabled_when_enabled_true() {
        let config = AppConfig {
            proxy: Some(ProxyConfig {
                enabled: true,
                url: "http://127.0.0.1:10808".to_string(),
            }),
        };
        assert!(config.proxy.as_ref().filter(|p| p.enabled).is_some());
    }
}
