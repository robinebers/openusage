mod config;
mod format_table;
mod format_json;

use clap::Parser;
use openusage_plugin_engine::{manifest, runtime};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, serde::Serialize)]
pub(crate) struct ProviderError {
    pub code: String,
    pub message: String,
}

pub(crate) fn extract_error_message(output: &runtime::PluginOutput) -> String {
    for line in &output.lines {
        if let runtime::MetricLine::Badge { label, text, .. } = line {
            if label == "Error" {
                return text.clone();
            }
        }
    }
    "unknown error".to_string()
}

#[derive(Parser)]
#[command(name = "openusage", about = "CLI tool for tracking AI coding subscription usage")]
struct Cli {
    /// Output JSON instead of table (for LLM agent consumption)
    #[arg(long)]
    json: bool,

    /// Filter to specific provider(s); repeatable
    #[arg(long = "provider", value_name = "ID")]
    providers: Vec<String>,

    /// Path to plugins directory
    #[arg(long, default_value = "./plugins")]
    plugins_dir: PathBuf,

    /// Path to app data directory
    #[arg(long)]
    data_dir: Option<PathBuf>,

    /// Enable verbose logging output
    #[arg(long, short)]
    verbose: bool,
}

fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("openusage")
}

fn main() {
    let cli = Cli::parse();

    let default_level = if cli.verbose { "debug" } else { "error" };
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(default_level))
        .init();

    let data_dir = cli.data_dir.unwrap_or_else(default_data_dir);
    if let Err(e) = std::fs::create_dir_all(&data_dir) {
        log::warn!("failed to create data dir: {}", e);
    }

    let plugins_dir = &cli.plugins_dir;
    if !plugins_dir.exists() {
        eprintln!("error: plugins directory not found: {}", plugins_dir.display());
        std::process::exit(1);
    }

    let plugins = manifest::load_plugins_from_dir(plugins_dir);
    if plugins.is_empty() {
        eprintln!("no plugins found in {}", plugins_dir.display());
        std::process::exit(1);
    }

    let mut errors: HashMap<String, ProviderError> = HashMap::new();

    let selected: Vec<_> = if cli.providers.is_empty() {
        plugins
    } else {
        // Collect unmatched provider IDs as errors
        let plugin_ids: Vec<&str> = plugins.iter().map(|p| p.manifest.id.as_str()).collect();
        for requested in &cli.providers {
            if !plugin_ids.contains(&requested.as_str()) {
                errors.insert(
                    requested.clone(),
                    ProviderError {
                        code: "provider_not_found".to_string(),
                        message: format!("no plugin matches provider '{}'", requested),
                    },
                );
            }
        }
        plugins
            .into_iter()
            .filter(|p| cli.providers.iter().any(|id| id == &p.manifest.id))
            .collect()
    };

    if selected.is_empty() && errors.is_empty() {
        eprintln!("no matching providers found");
        std::process::exit(1);
    }

    let version = env!("CARGO_PKG_VERSION");
    let outputs: Vec<runtime::PluginOutput> = std::thread::scope(|s| {
        let handles: Vec<_> = selected
            .iter()
            .map(|plugin| {
                let data = &data_dir;
                s.spawn(move || runtime::run_probe(plugin, &data.to_path_buf(), version))
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });

    // Partition outputs: error-only ones become ProviderErrors
    let (good, bad): (Vec<_>, Vec<_>) = outputs.into_iter().partition(|o| !is_error_only(o));
    for output in bad {
        let msg = extract_error_message(&output);
        errors.insert(
            output.provider_id.clone(),
            ProviderError {
                code: "plugin_error".to_string(),
                message: msg,
            },
        );
    }

    if cli.json {
        print!("{}", format_json::format(&good, &errors));
    } else {
        print!("{}", format_table::format(&good, &errors));
    }
}

fn is_error_only(output: &runtime::PluginOutput) -> bool {
    output.lines.iter().all(|line| {
        matches!(line, runtime::MetricLine::Badge { label, .. } if label == "Error")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openusage_plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};

    fn sample_output() -> PluginOutput {
        PluginOutput {
            provider_id: "test".to_string(),
            display_name: "Test Provider".to_string(),
            plan: Some("Pro".to_string()),
            lines: vec![
                MetricLine::Progress {
                    label: "Requests".to_string(),
                    used: 50.0,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: None,
                    period_duration_ms: None,
                    color: None,
                },
            ],
            icon_url: String::new(),
        }
    }

    #[test]
    fn is_error_only_returns_false_for_normal_output() {
        assert!(!is_error_only(&sample_output()));
    }

    #[test]
    fn is_error_only_returns_true_for_error_badge() {
        let output = PluginOutput {
            provider_id: "test".to_string(),
            display_name: "Test".to_string(),
            plan: None,
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "auth failed".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        };
        assert!(is_error_only(&output));
    }

    #[test]
    fn extract_error_message_extracts_error_badge_text() {
        let output = PluginOutput {
            provider_id: "copilot".to_string(),
            display_name: "Copilot".to_string(),
            plan: None,
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "Not logged in. Run `gh auth login` first.".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        };
        assert_eq!(
            extract_error_message(&output),
            "Not logged in. Run `gh auth login` first."
        );
    }

    #[test]
    fn extract_error_message_returns_fallback_for_non_error_output() {
        let output = sample_output();
        assert_eq!(extract_error_message(&output), "unknown error");
    }

    #[test]
    fn is_error_only_returns_false_for_mixed_lines() {
        let output = PluginOutput {
            provider_id: "test".to_string(),
            display_name: "Test".to_string(),
            plan: None,
            lines: vec![
                MetricLine::Badge {
                    label: "Error".to_string(),
                    text: "partial".to_string(),
                    color: None,
                    subtitle: None,
                },
                MetricLine::Text {
                    label: "Info".to_string(),
                    value: "ok".to_string(),
                    color: None,
                    subtitle: None,
                },
            ],
            icon_url: String::new(),
        };
        assert!(!is_error_only(&output));
    }
}
