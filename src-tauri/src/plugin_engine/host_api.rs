use rquickjs::{Ctx, Exception, Function, Object};
use std::path::PathBuf;

/// Redact sensitive value to first4...last4 format (UTF-8 safe)
fn redact_value(value: &str) -> String {
    let chars: Vec<char> = value.chars().collect();
    if chars.len() <= 12 {
        "[REDACTED]".to_string()
    } else {
        let first4: String = chars.iter().take(4).collect();
        let last4: String = chars.iter().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect();
        format!("{}...{}", first4, last4)
    }
}

/// Redact sensitive query parameters in URL
fn redact_url(url: &str) -> String {
    let sensitive_params = [
        "key", "api_key", "apikey", "token", "access_token", "secret",
        "password", "auth", "authorization", "bearer", "credential",
    ];
    
    if let Some(query_start) = url.find('?') {
        let (base, query) = url.split_at(query_start + 1);
        let redacted_params: Vec<String> = query
            .split('&')
            .map(|param| {
                if let Some(eq_pos) = param.find('=') {
                    let (name, value) = param.split_at(eq_pos);
                    let value = &value[1..]; // skip '='
                    let name_lower = name.to_lowercase();
                    if sensitive_params.iter().any(|s| name_lower.contains(s)) && !value.is_empty() {
                        format!("{}={}", name, redact_value(value))
                    } else {
                        param.to_string()
                    }
                } else {
                    param.to_string()
                }
            })
            .collect();
        format!("{}{}", base, redacted_params.join("&"))
    } else {
        url.to_string()
    }
}

/// Redact sensitive patterns in response body for logging
fn redact_body(body: &str) -> String {
    let mut result = body.to_string();
    
    // Redact JWTs (eyJ... pattern with dots)
    let jwt_pattern = regex_lite::Regex::new(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+").unwrap();
    result = jwt_pattern.replace_all(&result, |caps: &regex_lite::Captures| {
        redact_value(&caps[0])
    }).to_string();
    
    // Redact common API key patterns (sk-xxx, pk-xxx, api_xxx, etc.)
    let api_key_pattern = regex_lite::Regex::new(r#"["']?(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}["']?"#).unwrap();
    result = api_key_pattern.replace_all(&result, |caps: &regex_lite::Captures| {
        let key = caps[0].trim_matches(|c| c == '"' || c == '\'');
        redact_value(key)
    }).to_string();
    
    // Redact JSON values for sensitive keys
    let sensitive_keys = [
        "password", "token", "access_token", "refresh_token", "secret",
        "api_key", "apiKey", "authorization", "bearer", "credential",
        "session_token", "sessionToken", "auth_token", "authToken",
        "user_id", "account_id", "email", "login", "analytics_tracking_id",
    ];
    for key in sensitive_keys {
        // Match "key": "value" or "key":"value"
        let pattern = format!(r#""{}":\s*"([^"]+)""#, key);
        if let Ok(re) = regex_lite::Regex::new(&pattern) {
            result = re.replace_all(&result, |caps: &regex_lite::Captures| {
                let value = &caps[1];
                format!("\"{}\": \"{}\"", key, redact_value(value))
            }).to_string();
        }
    }
    
    result
}

/// Lightweight redaction for plugin log messages (JWT + API key patterns only).
fn redact_log_message(msg: &str) -> String {
    let mut result = msg.to_string();
    if let Ok(jwt_re) = regex_lite::Regex::new(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+") {
        result = jwt_re.replace_all(&result, |caps: &regex_lite::Captures| redact_value(&caps[0])).to_string();
    }
    if let Ok(api_re) = regex_lite::Regex::new(r#"(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}"#) {
        result = api_re.replace_all(&result, |caps: &regex_lite::Captures| redact_value(&caps[0])).to_string();
    }
    result
}

pub fn inject_host_api<'js>(
    ctx: &Ctx<'js>,
    plugin_id: &str,
    app_data_dir: &PathBuf,
    app_version: &str,
) -> rquickjs::Result<()> {
    let globals = ctx.globals();
    let probe_ctx = Object::new(ctx.clone())?;

    probe_ctx.set("nowIso", iso_now())?;

    let app_obj = Object::new(ctx.clone())?;
    app_obj.set("version", app_version)?;
    app_obj.set("platform", std::env::consts::OS)?;
    app_obj.set("appDataDir", app_data_dir.to_string_lossy().to_string())?;
    let plugin_data_dir = app_data_dir.join("plugins_data").join(plugin_id);
    if let Err(err) = std::fs::create_dir_all(&plugin_data_dir) {
        log::warn!(
            "[plugin:{}] failed to create plugin data dir: {}",
            plugin_id,
            err
        );
    }
    app_obj.set(
        "pluginDataDir",
        plugin_data_dir.to_string_lossy().to_string(),
    )?;
    probe_ctx.set("app", app_obj)?;

    let host = Object::new(ctx.clone())?;
    inject_log(ctx, &host, plugin_id)?;
    inject_fs(ctx, &host)?;
    inject_http(ctx, &host, plugin_id)?;
    inject_keychain(ctx, &host)?;
    inject_sqlite(ctx, &host)?;
    inject_ls(ctx, &host, plugin_id)?;

    probe_ctx.set("host", host)?;
    globals.set("__openusage_ctx", probe_ctx)?;

    Ok(())
}

fn inject_log<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    plugin_id: &str,
) -> rquickjs::Result<()> {
    let log_obj = Object::new(ctx.clone())?;

    let pid = plugin_id.to_string();
    log_obj.set(
        "info",
        Function::new(ctx.clone(), move |msg: String| {
            log::info!("[plugin:{}] {}", pid, redact_log_message(&msg));
        })?,
    )?;

    let pid = plugin_id.to_string();
    log_obj.set(
        "warn",
        Function::new(ctx.clone(), move |msg: String| {
            log::warn!("[plugin:{}] {}", pid, redact_log_message(&msg));
        })?,
    )?;

    let pid = plugin_id.to_string();
    log_obj.set(
        "error",
        Function::new(ctx.clone(), move |msg: String| {
            log::error!("[plugin:{}] {}", pid, redact_log_message(&msg));
        })?,
    )?;

    host.set("log", log_obj)?;
    Ok(())
}

fn inject_fs<'js>(ctx: &Ctx<'js>, host: &Object<'js>) -> rquickjs::Result<()> {
    let fs_obj = Object::new(ctx.clone())?;

    fs_obj.set(
        "exists",
        Function::new(ctx.clone(), move |path: String| -> bool {
            let expanded = expand_path(&path);
            std::path::Path::new(&expanded).exists()
        })?,
    )?;

    fs_obj.set(
        "readText",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, path: String| -> rquickjs::Result<String> {
                let expanded = expand_path(&path);
                std::fs::read_to_string(&expanded).map_err(|e| {
                    Exception::throw_message(&ctx_inner, &e.to_string())
                })
            },
        )?,
    )?;

    fs_obj.set(
        "writeText",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, path: String, content: String| -> rquickjs::Result<()> {
                let expanded = expand_path(&path);
                std::fs::write(&expanded, &content).map_err(|e| {
                    Exception::throw_message(&ctx_inner, &e.to_string())
                })
            },
        )?,
    )?;

    host.set("fs", fs_obj)?;
    Ok(())
}

fn inject_http<'js>(ctx: &Ctx<'js>, host: &Object<'js>, plugin_id: &str) -> rquickjs::Result<()> {
    let http_obj = Object::new(ctx.clone())?;
    let pid = plugin_id.to_string();

    http_obj.set(
        "_requestRaw",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, req_json: String| -> rquickjs::Result<String> {
                let req: HttpReqParams = serde_json::from_str(&req_json).map_err(|e| {
                    Exception::throw_message(&ctx_inner, &format!("invalid request: {}", e))
                })?;

                let method_str = req.method.as_deref().unwrap_or("GET");
                let redacted_url = redact_url(&req.url);
                log::info!("[plugin:{}] HTTP {} {}", pid, method_str, redacted_url);

                let mut header_map = reqwest::header::HeaderMap::new();
                if let Some(headers) = &req.headers {
                    for (key, val) in headers {
                        let name = reqwest::header::HeaderName::from_bytes(key.as_bytes())
                            .map_err(|e| {
                                Exception::throw_message(
                                    &ctx_inner,
                                    &format!("invalid header name '{}': {}", key, e),
                                )
                            })?;
                        let value = reqwest::header::HeaderValue::from_str(val).map_err(|e| {
                            Exception::throw_message(
                                &ctx_inner,
                                &format!("invalid header value for '{}': {}", key, e),
                            )
                        })?;
                        header_map.insert(name, value);
                    }
                }

                let timeout_ms = req.timeout_ms.unwrap_or(10_000);
                let mut builder = reqwest::blocking::Client::builder()
                    .timeout(std::time::Duration::from_millis(timeout_ms))
                    .redirect(reqwest::redirect::Policy::none());
                if req.dangerously_ignore_tls.unwrap_or(false) {
                    builder = builder.danger_accept_invalid_certs(true);
                }
                let client = builder
                    .build()
                    .map_err(|e| Exception::throw_message(&ctx_inner, &e.to_string()))?;

                let method = req.method.as_deref().unwrap_or("GET");
                let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| {
                    Exception::throw_message(
                        &ctx_inner,
                        &format!("invalid http method '{}': {}", method, e),
                    )
                })?;
                let mut builder = client.request(method, &req.url);
                builder = builder.headers(header_map);
                if let Some(body) = req.body_text {
                    builder = builder.body(body);
                }

                let response = builder
                    .send()
                    .map_err(|e| Exception::throw_message(&ctx_inner, &e.to_string()))?;

                let status = response.status().as_u16();
                let mut resp_headers = std::collections::HashMap::new();
                for (key, value) in response.headers().iter() {
                    let header_value = value.to_str().map_err(|e| {
                        Exception::throw_message(
                            &ctx_inner,
                            &format!("invalid response header '{}': {}", key, e),
                        )
                    })?;
                    resp_headers.insert(key.to_string(), header_value.to_string());
                }
                let body = response
                    .text()
                    .map_err(|e| Exception::throw_message(&ctx_inner, &e.to_string()))?;

                // Redact BEFORE truncation to ensure sensitive values are caught while intact
                let redacted_body = redact_body(&body);
                let body_preview = if redacted_body.len() > 500 {
                    // UTF-8 safe truncation: find valid char boundary at or before 500
                    let truncated: String = redacted_body.char_indices()
                        .take_while(|(i, _)| *i < 500)
                        .map(|(_, c)| c)
                        .collect();
                    format!("{}... ({} bytes total)", truncated, body.len())
                } else {
                    redacted_body
                };
                log::info!(
                    "[plugin:{}] HTTP {} {} -> {} | {}",
                    pid,
                    method_str,
                    redacted_url,
                    status,
                    body_preview
                );

                let resp = HttpRespParams {
                    status,
                    headers: resp_headers,
                    body_text: body,
                };

                serde_json::to_string(&resp)
                    .map_err(|e| Exception::throw_message(&ctx_inner, &e.to_string()))
            },
        )?,
    )?;

    ctx.eval::<(), _>(
        r#"
        (function() {
            // Will be patched after __openusage_ctx is set.
            if (typeof __openusage_ctx !== "undefined") {
                void 0;
            }
        })();
        "#
        .as_bytes(),
    )
    .map_err(|e| Exception::throw_message(ctx, &format!("http wrapper init failed: {}", e)))?;

    host.set("http", http_obj)?;
    Ok(())
}

pub fn patch_http_wrapper(ctx: &rquickjs::Ctx<'_>) -> rquickjs::Result<()> {
    ctx.eval::<(), _>(
        r#"
        (function() {
            var rawFn = __openusage_ctx.host.http._requestRaw;
            __openusage_ctx.host.http.request = function(req) {
                var json = JSON.stringify({
                    url: req.url,
                    method: req.method || "GET",
                    headers: req.headers || null,
                    bodyText: req.bodyText || null,
                    timeoutMs: req.timeoutMs || 10000,
                    dangerouslyIgnoreTls: req.dangerouslyIgnoreTls || false
                });
                var respJson = rawFn(json);
                return JSON.parse(respJson);
            };
        })();
        "#
        .as_bytes(),
    )
}

/// Inject utility APIs (line builders, formatters, base64, jwt) onto __openusage_ctx
pub fn inject_utils(ctx: &rquickjs::Ctx<'_>) -> rquickjs::Result<()> {
    ctx.eval::<(), _>(
        r#"
        (function() {
            var ctx = __openusage_ctx;

            // Line builders (options object API)
            ctx.line = {
                text: function(opts) {
                    var line = { type: "text", label: opts.label, value: opts.value };
                    if (opts.color) line.color = opts.color;
                    if (opts.subtitle) line.subtitle = opts.subtitle;
                    return line;
                },
                progress: function(opts) {
                    var line = { type: "progress", label: opts.label, used: opts.used, limit: opts.limit, format: opts.format };
                    if (opts.resetsAt) line.resetsAt = opts.resetsAt;
                    if (opts.periodDurationMs) line.periodDurationMs = opts.periodDurationMs;
                    if (opts.color) line.color = opts.color;
                    return line;
                },
                badge: function(opts) {
                    var line = { type: "badge", label: opts.label, text: opts.text };
                    if (opts.color) line.color = opts.color;
                    if (opts.subtitle) line.subtitle = opts.subtitle;
                    return line;
                }
            };

            // Formatters
            ctx.fmt = {
                planLabel: function(value) {
                    var text = String(value || "").trim();
                    if (!text) return "";
                    return text.replace(/(^|\s)([a-z])/g, function(match, space, letter) {
                        return space + letter.toUpperCase();
                    });
                },
                resetIn: function(secondsUntil) {
                    if (!Number.isFinite(secondsUntil) || secondsUntil < 0) return null;
                    var totalMinutes = Math.floor(secondsUntil / 60);
                    var totalHours = Math.floor(totalMinutes / 60);
                    var days = Math.floor(totalHours / 24);
                    var hours = totalHours % 24;
                    var minutes = totalMinutes % 60;
                    if (days > 0) return days + "d " + hours + "h";
                    if (totalHours > 0) return totalHours + "h " + minutes + "m";
                    if (totalMinutes > 0) return totalMinutes + "m";
                    return "<1m";
                },
                dollars: function(cents) {
                    var d = cents / 100;
                    return Math.round(d * 100) / 100;
                },
                date: function(unixMs) {
                    var d = new Date(Number(unixMs));
                    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
                    return months[d.getMonth()] + " " + String(d.getDate());
                }
            };

            // Shared utilities
            ctx.util = {
                tryParseJson: function(text) {
                    if (text === null || text === undefined) return null;
                    var trimmed = String(text).trim();
                    if (!trimmed) return null;
                    try {
                        return JSON.parse(trimmed);
                    } catch (e) {
                        return null;
                    }
                },
                safeJsonParse: function(text) {
                    if (text === null || text === undefined) return { ok: false };
                    var trimmed = String(text).trim();
                    if (!trimmed) return { ok: false };
                    try {
                        return { ok: true, value: JSON.parse(trimmed) };
                    } catch (e) {
                        return { ok: false };
                    }
                },
                request: function(opts) {
                    return ctx.host.http.request(opts);
                },
                requestJson: function(opts) {
                    var resp = ctx.util.request(opts);
                    var parsed = ctx.util.safeJsonParse(resp.bodyText);
                    return { resp: resp, json: parsed.ok ? parsed.value : null };
                },
                isAuthStatus: function(status) {
                    return status === 401 || status === 403;
                },
                retryOnceOnAuth: function(opts) {
                    var resp = opts.request();
                    if (ctx.util.isAuthStatus(resp.status)) {
                        var token = opts.refresh();
                        if (token) {
                            resp = opts.request(token);
                        }
                    }
                    return resp;
                },
                parseDateMs: function(value) {
                    if (value instanceof Date) {
                        var dateMs = value.getTime();
                        return Number.isFinite(dateMs) ? dateMs : null;
                    }
                    if (typeof value === "number") {
                        return Number.isFinite(value) ? value : null;
                    }
                    if (typeof value === "string") {
                        var parsed = Date.parse(value);
                        if (Number.isFinite(parsed)) return parsed;
                        var n = Number(value);
                        return Number.isFinite(n) ? n : null;
                    }
                    return null;
                },
                toIso: function(value) {
                    if (value === null || value === undefined) return null;

                    if (typeof value === "string") {
                        var s = String(value).trim();
                        if (!s) return null;

                        // Common variants
                        // - "YYYY-MM-DD HH:MM:SS" -> "YYYY-MM-DDTHH:MM:SS"
                        // - "... UTC" -> "...Z"
                        if (s.indexOf(" ") !== -1 && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(s)) {
                            s = s.replace(" ", "T");
                        }
                        if (s.endsWith(" UTC")) {
                            s = s.slice(0, -4) + "Z";
                        }

                        // Numeric strings: treat as seconds/ms.
                        if (/^-?\d+(\.\d+)?$/.test(s)) {
                            var n = Number(s);
                            if (!Number.isFinite(n)) return null;
                            var msNum = Math.abs(n) < 1e10 ? n * 1000 : n;
                            var dn = new Date(msNum);
                            var tn = dn.getTime();
                            if (!Number.isFinite(tn)) return null;
                            return dn.toISOString();
                        }

                        // Normalize timezone offsets without colon: "+0000" -> "+00:00"
                        if (/[+-]\d{4}$/.test(s)) {
                            s = s.replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
                        }

                        // Some APIs return RFC3339 with >3 fractional digits (e.g. .123456Z).
                        // Normalize to milliseconds so Date.parse can understand it.
                        var m = s.match(
                            /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$/
                        );
                        if (m) {
                            var head = m[1];
                            var frac = m[2] || "";
                            var tz = m[3];
                            if (frac) {
                                var digits = frac.slice(1);
                                if (digits.length > 3) digits = digits.slice(0, 3);
                                while (digits.length < 3) digits = digits + "0";
                                frac = "." + digits;
                            }
                            s = head + frac + tz;
                        } else {
                            // ISO-like but missing timezone: assume UTC.
                            var mNoTz = s.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?$/);
                            if (mNoTz) {
                                var head2 = mNoTz[1];
                                var frac2 = mNoTz[2] || "";
                                if (frac2) {
                                    var digits2 = frac2.slice(1);
                                    if (digits2.length > 3) digits2 = digits2.slice(0, 3);
                                    while (digits2.length < 3) digits2 = digits2 + "0";
                                    frac2 = "." + digits2;
                                }
                                s = head2 + frac2 + "Z";
                            }
                        }

                        var parsed = Date.parse(s);
                        if (!Number.isFinite(parsed)) return null;
                        return new Date(parsed).toISOString();
                    }

                    if (typeof value === "number") {
                        if (!Number.isFinite(value)) return null;
                        var ms = Math.abs(value) < 1e10 ? value * 1000 : value;
                        var d = new Date(ms);
                        var t = d.getTime();
                        if (!Number.isFinite(t)) return null;
                        return d.toISOString();
                    }

                    if (value instanceof Date) {
                        var t = value.getTime();
                        if (!Number.isFinite(t)) return null;
                        return value.toISOString();
                    }

                    return null;
                },
                needsRefreshByExpiry: function(opts) {
                    if (!opts) return true;
                    if (opts.expiresAtMs === null || opts.expiresAtMs === undefined) return true;
                    var nowMs = Number(opts.nowMs);
                    var expiresAtMs = Number(opts.expiresAtMs);
                    var bufferMs = Number(opts.bufferMs);
                    if (!Number.isFinite(nowMs)) return true;
                    if (!Number.isFinite(expiresAtMs)) return true;
                    if (!Number.isFinite(bufferMs)) bufferMs = 0;
                    return nowMs + bufferMs >= expiresAtMs;
                }
            };

            // Base64
            var b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            ctx.base64 = {
                decode: function(str) {
                    str = str.replace(/-/g, "+").replace(/_/g, "/");
                    while (str.length % 4) str += "=";
                    str = str.replace(/=+$/, "");
                    var result = "";
                    var len = str.length;
                    var i = 0;
                    while (i < len) {
                        var remaining = len - i;
                        var a = b64chars.indexOf(str.charAt(i++));
                        var b = b64chars.indexOf(str.charAt(i++));
                        var c = remaining > 2 ? b64chars.indexOf(str.charAt(i++)) : 0;
                        var d = remaining > 3 ? b64chars.indexOf(str.charAt(i++)) : 0;
                        var n = (a << 18) | (b << 12) | (c << 6) | d;
                        result += String.fromCharCode((n >> 16) & 0xff);
                        if (remaining > 2) result += String.fromCharCode((n >> 8) & 0xff);
                        if (remaining > 3) result += String.fromCharCode(n & 0xff);
                    }
                    return result;
                },
                encode: function(str) {
                    var result = "";
                    var len = str.length;
                    var i = 0;
                    while (i < len) {
                        var chunkStart = i;
                        var a = str.charCodeAt(i++);
                        var b = i < len ? str.charCodeAt(i++) : 0;
                        var c = i < len ? str.charCodeAt(i++) : 0;
                        var bytesInChunk = i - chunkStart;
                        var n = (a << 16) | (b << 8) | c;
                        result += b64chars.charAt((n >> 18) & 63);
                        result += b64chars.charAt((n >> 12) & 63);
                        result += bytesInChunk < 2 ? "=" : b64chars.charAt((n >> 6) & 63);
                        result += bytesInChunk < 3 ? "=" : b64chars.charAt(n & 63);
                    }
                    return result;
                }
            };

            // JWT
            ctx.jwt = {
                decodePayload: function(token) {
                    try {
                        var parts = token.split(".");
                        if (parts.length !== 3) return null;
                        var decoded = ctx.base64.decode(parts[1]);
                        return JSON.parse(decoded);
                    } catch (e) {
                        return null;
                    }
                }
            };
        })();
        "#
        .as_bytes(),
    )
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct HttpReqParams {
    url: String,
    method: Option<String>,
    headers: Option<std::collections::HashMap<String, String>>,
    body_text: Option<String>,
    timeout_ms: Option<u64>,
    dangerously_ignore_tls: Option<bool>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct HttpRespParams {
    status: u16,
    headers: std::collections::HashMap<String, String>,
    body_text: String,
}

// --- Language Server Discovery ---

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct LsDiscoverOpts {
    process_name: String,
    markers: Vec<String>,
    csrf_flag: String,
    port_flag: Option<String>,
    extra_flags: Option<Vec<String>>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct LsDiscoverResult {
    pid: i32,
    csrf: String,
    ports: Vec<i32>,
    extra: std::collections::HashMap<String, String>,
    extension_port: Option<i32>,
}

fn inject_ls<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    plugin_id: &str,
) -> rquickjs::Result<()> {
    let ls_obj = Object::new(ctx.clone())?;
    let pid = plugin_id.to_string();

    ls_obj.set(
        "_discoverRaw",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, opts_json: String| -> rquickjs::Result<String> {
                let opts: LsDiscoverOpts = serde_json::from_str(&opts_json).map_err(|e| {
                    Exception::throw_message(
                        &ctx_inner,
                        &format!("invalid discover opts: {}", e),
                    )
                })?;

                log::info!(
                    "[plugin:{}] LS discover: processName={}, markers={:?}",
                    pid,
                    opts.process_name,
                    opts.markers
                );

                let ps_output = match std::process::Command::new("/bin/ps")
                    .args(["-ax", "-o", "pid=,command="])
                    .output()
                {
                    Ok(o) => o,
                    Err(e) => {
                        log::warn!("[plugin:{}] ps failed: {}", pid, e);
                        return Ok("null".to_string());
                    }
                };

                if !ps_output.status.success() {
                    log::warn!("[plugin:{}] ps returned non-zero", pid);
                    return Ok("null".to_string());
                }

                let ps_stdout = String::from_utf8_lossy(&ps_output.stdout);
                let process_name_lower = opts.process_name.to_lowercase();
                let markers_lower: Vec<String> =
                    opts.markers.iter().map(|m| m.to_lowercase()).collect();

                // Find the target process. Marker patterns are Codeium-derived
                // (--app_data_dir <name> and /<name>/ path match). If a future
                // non-Codeium provider needs LS discovery, extend patterns here.
                let mut found: Option<(i32, String)> = None;

                for line in ps_stdout.lines() {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    let mut parts = trimmed.splitn(2, char::is_whitespace);
                    let pid_str = match parts.next() {
                        Some(s) => s.trim(),
                        None => continue,
                    };
                    let command = match parts.next() {
                        Some(s) => s.trim(),
                        None => continue,
                    };

                    let command_lower = command.to_lowercase();

                    if !command_lower.contains(&process_name_lower) {
                        continue;
                    }

                    let has_marker = markers_lower.iter().any(|m| {
                        command_lower.contains(&format!("--app_data_dir {}", m))
                            || command_lower.contains(&format!("/{}/", m))
                    });
                    if !has_marker {
                        continue;
                    }

                    if let Ok(p) = pid_str.parse::<i32>() {
                        found = Some((p, command.to_string()));
                        break;
                    }
                }

                let (process_pid, command) = match found {
                    Some(pair) => pair,
                    None => {
                        log::info!("[plugin:{}] LS process not found", pid);
                        return Ok("null".to_string());
                    }
                };

                // Extract CSRF token
                let csrf = match ls_extract_flag(&command, &opts.csrf_flag) {
                    Some(c) => c,
                    None => {
                        log::warn!(
                            "[plugin:{}] CSRF token not found in process args",
                            pid
                        );
                        return Ok("null".to_string());
                    }
                };

                // Extract extension port (optional)
                let extension_port = opts
                    .port_flag
                    .as_ref()
                    .and_then(|flag| {
                        ls_extract_flag(&command, flag)
                            .and_then(|v| v.parse::<i32>().ok())
                    });

                // Extract extra flags (optional)
                let mut extra = std::collections::HashMap::new();
                if let Some(ref flags) = opts.extra_flags {
                    for flag in flags {
                        if let Some(val) = ls_extract_flag(&command, flag) {
                            // Use flag name without leading dashes as key
                            let key = flag.trim_start_matches('-').to_string();
                            extra.insert(key, val);
                        }
                    }
                }

                // Find lsof binary
                let lsof_path = ["/usr/sbin/lsof", "/usr/bin/lsof"]
                    .iter()
                    .find(|p| std::path::Path::new(p).exists())
                    .copied();

                let ports = if let Some(lsof) = lsof_path {
                    match std::process::Command::new(lsof)
                        .args([
                            "-nP",
                            "-iTCP",
                            "-sTCP:LISTEN",
                            "-a",
                            "-p",
                            &process_pid.to_string(),
                        ])
                        .output()
                    {
                        Ok(o) if o.status.success() => {
                            ls_parse_listening_ports(
                                &String::from_utf8_lossy(&o.stdout),
                            )
                        }
                        Ok(_) => {
                            log::warn!(
                                "[plugin:{}] lsof returned non-zero",
                                pid
                            );
                            Vec::new()
                        }
                        Err(e) => {
                            log::warn!("[plugin:{}] lsof failed: {}", pid, e);
                            Vec::new()
                        }
                    }
                } else {
                    log::warn!("[plugin:{}] lsof not found", pid);
                    Vec::new()
                };

                if ports.is_empty() && extension_port.is_none() {
                    log::warn!(
                        "[plugin:{}] no listening ports found for pid {}",
                        pid,
                        process_pid
                    );
                    return Ok("null".to_string());
                }

                log::info!(
                    "[plugin:{}] LS found: pid={}, ports={:?}, csrf=[REDACTED]",
                    pid,
                    process_pid,
                    ports
                );

                let result = LsDiscoverResult {
                    pid: process_pid,
                    csrf,
                    ports,
                    extra,
                    extension_port,
                };

                serde_json::to_string(&result).map_err(|e| {
                    Exception::throw_message(
                        &ctx_inner,
                        &format!("serialize failed: {}", e),
                    )
                })
            },
        )?,
    )?;

    host.set("ls", ls_obj)?;
    Ok(())
}

pub fn patch_ls_wrapper(ctx: &rquickjs::Ctx<'_>) -> rquickjs::Result<()> {
    ctx.eval::<(), _>(
        r#"
        (function() {
            var rawFn = __openusage_ctx.host.ls._discoverRaw;
            __openusage_ctx.host.ls.discover = function(opts) {
                var optsJson;
                try { optsJson = JSON.stringify(opts); } catch (e) { return null; }
                var json = rawFn(optsJson);
                if (json === "null") return null;
                return JSON.parse(json);
            };
        })();
        "#
        .as_bytes(),
    )
}

/// Extract value of a CLI flag from a command string.
/// Handles both `--flag value` and `--flag=value` forms.
fn ls_extract_flag(command: &str, flag: &str) -> Option<String> {
    let parts: Vec<&str> = command.split_whitespace().collect();
    let flag_eq = format!("{}=", flag);
    for (i, part) in parts.iter().enumerate() {
        if *part == flag {
            if i + 1 < parts.len() {
                return Some(parts[i + 1].to_string());
            }
        } else if part.starts_with(&flag_eq) {
            return Some(part[flag_eq.len()..].to_string());
        }
    }
    None
}

/// Parse listening port numbers from `lsof -nP -iTCP -sTCP:LISTEN` output.
fn ls_parse_listening_ports(output: &str) -> Vec<i32> {
    let mut ports = std::collections::BTreeSet::new();
    for line in output.lines() {
        if !line.contains("LISTEN") {
            continue;
        }
        // lsof -nP output: ... TCP 127.0.0.1:PORT (LISTEN)  or  ... TCP *:PORT
        // Scan tokens in reverse to find the address:port token.
        for token in line.split_whitespace().rev() {
            if let Some(colon_pos) = token.rfind(':') {
                let port_str = &token[colon_pos + 1..];
                if let Ok(port) = port_str.parse::<i32>() {
                    if port > 0 && port < 65536 {
                        ports.insert(port);
                        break;
                    }
                }
            }
        }
    }
    ports.into_iter().collect()
}

fn inject_keychain<'js>(ctx: &Ctx<'js>, host: &Object<'js>) -> rquickjs::Result<()> {
    let keychain_obj = Object::new(ctx.clone())?;

    keychain_obj.set(
        "readGenericPassword",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, service: String| -> rquickjs::Result<String> {
                if !cfg!(target_os = "macos") {
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        "keychain API is only supported on macOS",
                    ));
                }
                let output = std::process::Command::new("security")
                    .args(["find-generic-password", "-s", &service, "-w"])
                    .output()
                    .map_err(|e| {
                        Exception::throw_message(
                            &ctx_inner,
                            &format!("keychain read failed: {}", e),
                        )
                    })?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    let first_line = stderr.lines().next().unwrap_or("").trim();
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        &format!("keychain item not found: {}", first_line),
                    ));
                }

                Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
            },
        )?,
    )?;

    keychain_obj.set(
        "writeGenericPassword",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, service: String, value: String| -> rquickjs::Result<()> {
                if !cfg!(target_os = "macos") {
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        "keychain API is only supported on macOS",
                    ));
                }

                // First, try to find existing entry and extract its account
                let mut account_arg: Option<String> = None;
                let find_output = std::process::Command::new("security")
                    .args(["find-generic-password", "-s", &service])
                    .output();

                if let Ok(output) = find_output {
                    if output.status.success() {
                        // Parse account from output: "acct"<blob>="value"
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        for line in stdout.lines() {
                            if let Some(start) = line.find("\"acct\"<blob>=\"") {
                                let rest = &line[start + 14..];
                                if let Some(end) = rest.find('"') {
                                    account_arg = Some(rest[..end].to_string());
                                    break;
                                }
                            }
                        }
                    }
                }

                // Build command with account if found
                let output = if let Some(ref acct) = account_arg {
                    std::process::Command::new("security")
                        .args([
                            "add-generic-password",
                            "-s",
                            &service,
                            "-a",
                            acct,
                            "-w",
                            &value,
                            "-U",
                        ])
                        .output()
                } else {
                    std::process::Command::new("security")
                        .args([
                            "add-generic-password",
                            "-s",
                            &service,
                            "-w",
                            &value,
                            "-U",
                        ])
                        .output()
                }
                .map_err(|e| {
                    Exception::throw_message(
                        &ctx_inner,
                        &format!("keychain write failed: {}", e),
                    )
                })?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    let first_line = stderr.lines().next().unwrap_or("").trim();
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        &format!("keychain write failed: {}", first_line),
                    ));
                }

                Ok(())
            },
        )?,
    )?;

    host.set("keychain", keychain_obj)?;
    Ok(())
}

fn inject_sqlite<'js>(ctx: &Ctx<'js>, host: &Object<'js>) -> rquickjs::Result<()> {
    let sqlite_obj = Object::new(ctx.clone())?;

    sqlite_obj.set(
        "query",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, db_path: String, sql: String| -> rquickjs::Result<String> {
                if sql.lines().any(|line| line.trim_start().starts_with('.')) {
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        "sqlite3 dot-commands are not allowed",
                    ));
                }
                let expanded = expand_path(&db_path);
                // Use immutable=1 to bypass WAL/SHM file access issues
                // (WAL databases can fail with -readonly when shm is locked after macOS sleep)
                // Percent-encode special chars for valid URI (% must be first!)
                let encoded = expanded
                    .replace('%', "%25")
                    .replace(' ', "%20")
                    .replace('#', "%23")
                    .replace('?', "%3F");
                let uri_path = format!("file:{}?immutable=1", encoded);
                let output = std::process::Command::new("sqlite3")
                    .args(["-readonly", "-json", &uri_path, &sql])
                    .output()
                    .map_err(|e| {
                        Exception::throw_message(
                            &ctx_inner,
                            &format!("sqlite3 exec failed: {}", e),
                        )
                    })?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        &format!("sqlite3 error: {}", stderr.trim()),
                    ));
                }

                Ok(String::from_utf8_lossy(&output.stdout).to_string())
            },
        )?,
    )?;

    sqlite_obj.set(
        "exec",
        Function::new(
            ctx.clone(),
            move |ctx_inner: Ctx<'_>, db_path: String, sql: String| -> rquickjs::Result<()> {
                if sql.lines().any(|line| line.trim_start().starts_with('.')) {
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        "sqlite3 dot-commands are not allowed",
                    ));
                }
                let expanded = expand_path(&db_path);
                let output = std::process::Command::new("sqlite3")
                    .args([&expanded, &sql])
                    .output()
                    .map_err(|e| {
                        Exception::throw_message(
                            &ctx_inner,
                            &format!("sqlite3 exec failed: {}", e),
                        )
                    })?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(Exception::throw_message(
                        &ctx_inner,
                        &format!("sqlite3 error: {}", stderr.trim()),
                    ));
                }

                Ok(())
            },
        )?,
    )?;

    host.set("sqlite", sqlite_obj)?;
    Ok(())
}

fn iso_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|err| {
            log::error!("nowIso format failed: {}", err);
            "1970-01-01T00:00:00Z".to_string()
        })
}

fn expand_path(path: &str) -> String {
    if path == "~" {
        if let Some(home) = dirs::home_dir() {
            return home.to_string_lossy().to_string();
        }
    }
    if path.starts_with("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(&path[2..]).to_string_lossy().to_string();
        }
    }
    path.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rquickjs::{Context, Function, Object, Runtime};

    #[test]
    fn keychain_api_exposes_write() {
        let rt = Runtime::new().expect("runtime");
        let ctx = Context::full(&rt).expect("context");
        ctx.with(|ctx| {
            let app_data = std::env::temp_dir();
            inject_host_api(&ctx, "test", &app_data, "0.0.0").expect("inject host api");
            let globals = ctx.globals();
            let probe_ctx: Object = globals.get("__openusage_ctx").expect("probe ctx");
            let host: Object = probe_ctx.get("host").expect("host");
            let keychain: Object = host.get("keychain").expect("keychain");
            let _read: Function = keychain
                .get("readGenericPassword")
                .expect("readGenericPassword");
            let _write: Function = keychain
                .get("writeGenericPassword")
                .expect("writeGenericPassword");
        });
    }

    #[test]
    fn redact_value_shows_first_and_last_four() {
        assert_eq!(redact_value("sk-1234567890abcdef"), "sk-1...cdef");
        assert_eq!(redact_value("short"), "[REDACTED]");
    }

    #[test]
    fn redact_url_redacts_api_key_param() {
        let url = "https://api.example.com/v1?api_key=sk-1234567890abcdef&other=value";
        let redacted = redact_url(url);
        assert!(redacted.contains("api_key=sk-1...cdef"));
        assert!(redacted.contains("other=value"));
    }

    #[test]
    fn redact_url_preserves_non_sensitive_params() {
        let url = "https://api.example.com/v1?limit=10&offset=20";
        assert_eq!(redact_url(url), url);
    }

    #[test]
    fn redact_body_redacts_jwt() {
        let body = r#"{"token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"}"#;
        let redacted = redact_body(body);
        // JWT gets redacted to first4...last4 format
        assert!(!redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), "full JWT should be redacted, got: {}", redacted);
    }

    #[test]
    fn redact_body_redacts_api_keys() {
        let body = r#"{"key": "sk-1234567890abcdefghij"}"#;
        let redacted = redact_body(body);
        assert!(redacted.contains("sk-1...ghij"));
    }

    #[test]
    fn redact_body_redacts_json_password_field() {
        let body = r#"{"password": "supersecretpassword123"}"#;
        let redacted = redact_body(body);
        assert!(!redacted.contains("supersecretpassword123"), "password should be redacted, got: {}", redacted);
    }

    #[test]
    fn redact_body_redacts_user_id_and_email() {
        let body = r#"{"user_id": "user-iupzZ7KFykMLrnzpkHSq7wjo", "email": "rob@sunstory.com"}"#;
        let redacted = redact_body(body);
        assert!(!redacted.contains("user-iupzZ7KFykMLrnzpkHSq7wjo"), "user_id should be redacted, got: {}", redacted);
        assert!(!redacted.contains("rob@sunstory.com"), "email should be redacted, got: {}", redacted);
        // Should show first4...last4
        assert!(redacted.contains("user...7wjo"), "user_id should show first4...last4, got: {}", redacted);
        assert!(redacted.contains("rob@....com"), "email should show first4...last4, got: {}", redacted);
    }

    #[test]
    fn redact_log_message_redacts_jwt_and_api_key() {
        let msg = "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U key=sk-1234567890abcdef";
        let redacted = redact_log_message(msg);
        assert!(!redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), "JWT should be redacted");
        assert!(!redacted.contains("sk-1234567890abcdef"), "API key should be redacted");
    }

    #[test]
    fn redact_body_redacts_login_and_analytics_tracking_id() {
        let body = r#"{"login":"robinebers","analytics_tracking_id":"c9df3f012bb8c2eb7aae6868ee8da6cf"}"#;
        let redacted = redact_body(body);
        assert!(!redacted.contains("robinebers"), "login should be redacted, got: {}", redacted);
        assert!(!redacted.contains("c9df3f012bb8c2eb7aae6868ee8da6cf"), "analytics_tracking_id should be redacted, got: {}", redacted);
        // login is short (<=12 chars) so becomes [REDACTED]; analytics_tracking_id is long so first4...last4
        assert!(redacted.contains("[REDACTED]"), "login should be redacted, got: {}", redacted);
        assert!(redacted.contains("c9df...a6cf"), "analytics_tracking_id should show first4...last4, got: {}", redacted);
    }
}
