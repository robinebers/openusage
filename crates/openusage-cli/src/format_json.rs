use crate::ProviderError;
use openusage_plugin_engine::runtime::PluginOutput;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize)]
struct JsonOutput<'a> {
    providers: Vec<JsonProvider<'a>>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    errors: HashMap<&'a str, &'a ProviderError>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonProvider<'a> {
    provider_id: &'a str,
    display_name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    plan: Option<&'a str>,
    lines: &'a [openusage_plugin_engine::runtime::MetricLine],
}

pub fn format(outputs: &[PluginOutput], errors: &HashMap<String, ProviderError>) -> String {
    let providers: Vec<JsonProvider> = outputs
        .iter()
        .map(|o| JsonProvider {
            provider_id: &o.provider_id,
            display_name: &o.display_name,
            plan: o.plan.as_deref(),
            lines: &o.lines,
        })
        .collect();

    let json_errors: HashMap<&str, &ProviderError> = errors
        .iter()
        .map(|(k, v)| (k.as_str(), v))
        .collect();

    let wrapper = JsonOutput {
        providers,
        errors: json_errors,
    };
    serde_json::to_string_pretty(&wrapper).unwrap_or_else(|e| {
        format!("{{\"error\": \"{}\"}}", e)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openusage_plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};

    fn sample_output() -> PluginOutput {
        PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: Some("Max (5x)".to_string()),
            lines: vec![
                MetricLine::Progress {
                    label: "Session".to_string(),
                    used: 80.0,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: None,
                    period_duration_ms: None,
                    color: None,
                },
                MetricLine::Text {
                    label: "Today".to_string(),
                    value: "1.5M tokens".to_string(),
                    color: None,
                    subtitle: None,
                },
            ],
            icon_url: "data:image/svg+xml;base64,AAAA".to_string(),
        }
    }

    #[test]
    fn json_output_contains_providers_key() {
        let output = format(&[sample_output()], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert!(parsed.get("providers").is_some());
    }

    #[test]
    fn json_output_strips_icon_url() {
        let output = format(&[sample_output()], &HashMap::new());
        assert!(!output.contains("iconUrl"), "icon_url should be stripped from JSON output");
        assert!(!output.contains("icon_url"), "icon_url should be stripped from JSON output");
        assert!(!output.contains("AAAA"), "base64 icon data should not appear");
    }

    #[test]
    fn json_output_includes_provider_fields() {
        let output = format(&[sample_output()], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        let provider = &parsed["providers"][0];
        assert_eq!(provider["providerId"], "claude");
        assert_eq!(provider["displayName"], "Claude");
        assert_eq!(provider["plan"], "Max (5x)");
    }

    #[test]
    fn json_output_includes_lines() {
        let output = format(&[sample_output()], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        let lines = parsed["providers"][0]["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["type"], "progress");
        assert_eq!(lines[0]["label"], "Session");
        assert_eq!(lines[1]["type"], "text");
    }

    #[test]
    fn json_output_skips_null_plan() {
        let mut o = sample_output();
        o.plan = None;
        let output = format(&[o], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert!(parsed["providers"][0].get("plan").is_none());
    }

    #[test]
    fn json_output_empty_providers() {
        let output = format(&[], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed["providers"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn json_output_no_errors_key_when_empty() {
        let output = format(&[sample_output()], &HashMap::new());
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert!(parsed.get("errors").is_none(), "errors key should be absent when no errors");
    }

    #[test]
    fn json_output_includes_errors_key_when_present() {
        let mut errors = HashMap::new();
        errors.insert(
            "claude".to_string(),
            ProviderError {
                code: "provider_not_found".to_string(),
                message: "no plugin matches provider 'claude'".to_string(),
            },
        );
        let output = format(&[], &errors);
        let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
        let errs = parsed.get("errors").expect("errors key should be present");
        let claude_err = errs.get("claude").expect("should have claude error");
        assert_eq!(claude_err["code"], "provider_not_found");
        assert_eq!(claude_err["message"], "no plugin matches provider 'claude'");
    }
}
