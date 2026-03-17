mod format_table;
mod format_json;

use clap::Parser;
use openusage_plugin_engine::{manifest, runtime};
use std::path::PathBuf;

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
}

fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("openusage")
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("error"))
        .init();

    let cli = Cli::parse();

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

    let selected: Vec<_> = if cli.providers.is_empty() {
        plugins
    } else {
        plugins
            .into_iter()
            .filter(|p| cli.providers.iter().any(|id| id == &p.manifest.id))
            .collect()
    };

    if selected.is_empty() {
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

    // Filter out error-only results (unauthenticated providers)
    let outputs: Vec<_> = outputs
        .into_iter()
        .filter(|o| !is_error_only(o))
        .collect();

    if cli.json {
        print!("{}", format_json::format(&outputs));
    } else {
        print!("{}", format_table::format(&outputs));
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
