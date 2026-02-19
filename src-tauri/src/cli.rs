use crate::plugin_engine::manifest::{LoadedPlugin, load_plugins_from_dir};
use crate::plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat, run_probe};
use std::path::PathBuf;

#[derive(Debug, PartialEq, Eq)]
struct CliArgs {
    provider: Option<String>,
    help: bool,
}

#[derive(Debug, PartialEq, Eq)]
enum ParseResult {
    NotCli,
    Args(CliArgs),
    Error(String),
}

pub fn run_from_env() -> bool {
    match parse_args(std::env::args().skip(1)) {
        ParseResult::NotCli => false,
        ParseResult::Error(error) => {
            eprintln!("Error: {}", error);
            eprintln!("Usage: openusage --provider=<id>");
            std::process::exit(2);
        }
        ParseResult::Args(args) => {
            if args.help {
                print_help();
                return true;
            }

            match args.provider {
                Some(provider) => {
                    // Single provider mode
                    match run_provider(&provider) {
                        Ok(text) => {
                            println!("{}", text);
                            std::process::exit(0);
                        }
                        Err(error) => {
                            eprintln!("Error: {}", error);
                            std::process::exit(1);
                        }
                    }
                }
                None => {
                    // All providers mode
                    match run_all_providers() {
                        Ok(text) => {
                            println!("{}", text);
                            std::process::exit(0);
                        }
                        Err(error) => {
                            eprintln!("Error: {}", error);
                            std::process::exit(2);
                        }
                    }
                }
            }
        }
    }
}

fn run_provider(provider_id: &str) -> Result<String, String> {
    let plugin_dir = resolve_plugins_dir().ok_or_else(|| {
        "could not locate plugins directory. Run from repo root or set OPENUSAGE_PLUGINS_DIR."
            .to_string()
    })?;
    let plugins = load_plugins_from_dir(&plugin_dir);
    if plugins.is_empty() {
        return Err(format!("no plugins found in {}", plugin_dir.display()));
    }

    let plugin = select_plugin(&plugins, provider_id)
        .ok_or_else(|| format!("provider '{}' not found", provider_id))?;

    let app_data_dir = resolve_app_data_dir()?;
    let output = run_probe(plugin, &app_data_dir, env!("CARGO_PKG_VERSION"));
    format_output(output)
}

fn run_all_providers() -> Result<String, String> {
    let plugin_dir = resolve_plugins_dir().ok_or_else(|| {
        "could not locate plugins directory. Run from repo root or set OPENUSAGE_PLUGINS_DIR."
            .to_string()
    })?;
    let plugins = load_plugins_from_dir(&plugin_dir);
    if plugins.is_empty() {
        return Err(format!("no plugins found in {}", plugin_dir.display()));
    }

    let app_data_dir = resolve_app_data_dir()?;

    // Probe all plugins and collect results
    let mut outputs = Vec::new();
    for plugin in &plugins {
        let output = run_probe(plugin, &app_data_dir, env!("CARGO_PKG_VERSION"));
        outputs.push(output);
    }

    format_table_output(outputs)
}

fn parse_args<I>(args: I) -> ParseResult
where
    I: IntoIterator<Item = String>,
{
    let mut provider: Option<String> = None;
    let mut help = false;
    let mut cli_mode = false;

    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        if arg == "--help" || arg == "-h" {
            help = true;
            cli_mode = true;
            continue;
        }

        if let Some(value) = arg.strip_prefix("--provider=") {
            provider = Some(value.trim().to_string());
            cli_mode = true;
            continue;
        }

        if arg == "--provider" {
            cli_mode = true;
            let value = iter.next().unwrap_or_default();
            // Prevent consuming flags like --help as provider IDs
            if value.starts_with("--") {
                return ParseResult::Error(format!("--provider requires a value, got '{}'", value));
            }
            provider = Some(value.trim().to_string());
            continue;
        }

        if arg.starts_with("--provider") {
            return ParseResult::Error(format!("invalid --provider argument '{}'", arg));
        }
    }

    if !cli_mode {
        return ParseResult::NotCli;
    }

    if let Some(p) = &provider {
        if p.is_empty() {
            return ParseResult::Error("provider cannot be empty".to_string());
        }
    }

    ParseResult::Args(CliArgs { provider, help })
}

fn print_help() {
    println!("OpenUsage CLI");
    println!();
    println!("Usage:");
    println!("  openusage                    # Show all providers");
    println!("  openusage --provider=<id>    # Show specific provider");
    println!();
    println!("Example:");
    println!("  openusage");
    println!("  openusage --provider=claude");
}

fn select_plugin<'a>(plugins: &'a [LoadedPlugin], provider_id: &str) -> Option<&'a LoadedPlugin> {
    let target = provider_id.trim().to_lowercase();
    plugins
        .iter()
        .find(|plugin| plugin.manifest.id.to_lowercase() == target)
}

fn resolve_plugins_dir() -> Option<PathBuf> {
    if let Ok(from_env) = std::env::var("OPENUSAGE_PLUGINS_DIR") {
        let path = PathBuf::from(from_env);
        if path.exists() {
            return Some(path);
        }
    }

    let cwd = std::env::current_dir().ok()?;
    let candidates = [
        cwd.join("plugins"),
        cwd.join("..").join("plugins"),
        resolve_app_data_dir().ok()?.join("plugins"),
    ];

    candidates.into_iter().find(|path| path.exists())
}

fn resolve_app_data_dir() -> Result<PathBuf, String> {
    let mut dir = dirs::data_local_dir().unwrap_or_else(std::env::temp_dir);
    // Use the same bundle identifier as the Tauri GUI app (from tauri.conf.json)
    // so CLI and GUI share the same plugins_data, credentials, and state.
    dir.push("com.sunstory.openusage");
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("failed to create app data dir {}: {}", dir.display(), error))?;
    Ok(dir)
}

fn format_table_output(outputs: Vec<PluginOutput>) -> Result<String, String> {
    let mut table = String::new();

    // Header row
    table.push_str("Provider    Plan      Session      Weekly\n");
    table.push_str("----------------------------------------\n");

    for output in outputs {
        // Extract data (with error handling for N/A)
        let plan = extract_plan(&output);
        let session = extract_session(&output);
        let weekly = extract_weekly(&output);

        // Format row with padding
        table.push_str(&format!(
            "{:<12}{:<10}{:<13}{}\n",
            truncate(&output.display_name, 11),
            truncate(&plan, 9),
            truncate(&session, 12),
            weekly
        ));
    }

    Ok(table)
}

fn extract_plan(output: &PluginOutput) -> String {
    if has_error(&output.lines) {
        return "N/A".to_string();
    }
    output
        .plan
        .as_ref()
        .filter(|p| !p.trim().is_empty())
        .map(|p| p.trim().to_string())
        .unwrap_or_else(|| "N/A".to_string())
}

fn extract_session(output: &PluginOutput) -> String {
    if has_error(&output.lines) {
        return "N/A".to_string();
    }
    let line = find_progress_line(&output.lines, "session");
    format_progress(line)
}

fn extract_weekly(output: &PluginOutput) -> String {
    if has_error(&output.lines) {
        return "N/A".to_string();
    }
    let line = find_progress_line(&output.lines, "weekly");
    format_progress(line)
}

fn has_error(lines: &[MetricLine]) -> bool {
    lines.iter().any(|line| {
        matches!(line,
            MetricLine::Badge { label, .. } if label.eq_ignore_ascii_case("error")
        )
    })
}

fn truncate(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}…", &s[..max_len - 1])
    }
}

fn format_output(output: PluginOutput) -> Result<String, String> {
    if let Some(error) = output.lines.iter().find_map(extract_error_line) {
        return Err(error.to_string());
    }

    let session = find_progress_line(&output.lines, "session");
    let weekly = find_progress_line(&output.lines, "weekly");

    let mut out = String::new();
    out.push_str(&format!("Provider: {}\n", output.display_name));
    if let Some(plan) = output
        .plan
        .as_ref()
        .filter(|value| !value.trim().is_empty())
    {
        out.push_str(&format!("Plan: {}\n", plan.trim()));
    }
    out.push_str(&format!("Session: {}\n", format_progress(session)));
    out.push_str(&format!("Session reset: {}\n", format_reset(session)));
    out.push_str(&format!("Weekly: {}\n", format_progress(weekly)));
    out.push_str(&format!("Weekly reset: {}", format_reset(weekly)));
    Ok(out)
}

fn extract_error_line(line: &MetricLine) -> Option<&str> {
    match line {
        MetricLine::Badge { label, text, .. } if label.eq_ignore_ascii_case("error") => {
            Some(text.as_str())
        }
        _ => None,
    }
}

fn find_progress_line<'a>(lines: &'a [MetricLine], label: &str) -> Option<&'a MetricLine> {
    lines.iter().find(|line| match line {
        MetricLine::Progress {
            label: line_label, ..
        } => line_label.eq_ignore_ascii_case(label),
        _ => false,
    })
}

fn format_progress(line: Option<&MetricLine>) -> String {
    match line {
        Some(MetricLine::Progress {
            used,
            limit,
            format: ProgressFormat::Percent,
            ..
        }) if *limit > 0.0 => format!("{}%", format_number(*used)),
        Some(MetricLine::Progress { used, limit, .. }) if *limit > 0.0 => {
            format!("{}/{}", format_number(*used), format_number(*limit))
        }
        _ => "n/a".to_string(),
    }
}

fn format_reset(line: Option<&MetricLine>) -> String {
    match line {
        Some(MetricLine::Progress {
            resets_at: Some(value),
            ..
        }) => value.to_string(),
        _ => "n/a".to_string(),
    }
}

fn format_number(value: f64) -> String {
    if !value.is_finite() {
        return "n/a".to_string();
    }
    if (value - value.round()).abs() < 0.000_000_1 {
        return format!("{:.0}", value);
    }
    let text = format!("{:.1}", value);
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_returns_not_cli_when_no_flags() {
        assert_eq!(parse_args(vec![]), ParseResult::NotCli);
    }

    #[test]
    fn parse_args_supports_provider_equals_syntax() {
        assert_eq!(
            parse_args(vec!["--provider=claude".to_string()]),
            ParseResult::Args(CliArgs {
                provider: Some("claude".to_string()),
                help: false,
            })
        );
    }

    #[test]
    fn parse_args_supports_provider_space_syntax() {
        assert_eq!(
            parse_args(vec!["--provider".to_string(), "claude".to_string()]),
            ParseResult::Args(CliArgs {
                provider: Some("claude".to_string()),
                help: false,
            })
        );
    }

    #[test]
    fn parse_args_rejects_empty_provider() {
        assert_eq!(
            parse_args(vec!["--provider=".to_string()]),
            ParseResult::Error("provider cannot be empty".to_string())
        );
    }

    #[test]
    fn parse_args_rejects_flag_as_provider_value() {
        // Prevent --help being consumed as provider ID
        assert_eq!(
            parse_args(vec!["--provider".to_string(), "--help".to_string()]),
            ParseResult::Error("--provider requires a value, got '--help'".to_string())
        );
    }

    #[test]
    fn format_output_prints_expected_fields() {
        let output = PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: Some("Max".to_string()),
            lines: vec![
                MetricLine::Progress {
                    label: "Session".to_string(),
                    used: 37.5,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: Some("2026-02-20T12:00:00Z".to_string()),
                    period_duration_ms: Some(5 * 60 * 60 * 1000),
                    color: None,
                },
                MetricLine::Progress {
                    label: "Weekly".to_string(),
                    used: 62.0,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: Some("2026-02-23T00:00:00Z".to_string()),
                    period_duration_ms: Some(7 * 24 * 60 * 60 * 1000),
                    color: None,
                },
            ],
            icon_url: String::new(),
        };

        let text = format_output(output).expect("format should succeed");
        assert!(text.contains("Provider: Claude"));
        assert!(text.contains("Plan: Max"));
        assert!(text.contains("Session: 37.5%"));
        assert!(text.contains("Weekly: 62%"));
        assert!(text.contains("Session reset: 2026-02-20T12:00:00Z"));
        assert!(text.contains("Weekly reset: 2026-02-23T00:00:00Z"));
    }

    #[test]
    fn format_output_propagates_plugin_error() {
        let output = PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: None,
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "Not logged in".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        };

        assert_eq!(
            format_output(output).expect_err("error should be returned"),
            "Not logged in"
        );
    }

    #[test]
    fn format_output_handles_missing_lines() {
        let output = PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: None,
            lines: vec![],
            icon_url: String::new(),
        };

        let text = format_output(output).expect("format should succeed");
        assert!(text.contains("Session: n/a"));
        assert!(text.contains("Weekly: n/a"));
    }

    #[test]
    fn parse_args_allows_no_provider_with_help() {
        // Help flag should work without provider
        assert_eq!(
            parse_args(vec!["--help".to_string()]),
            ParseResult::Args(CliArgs {
                provider: None,
                help: true,
            })
        );
    }

    #[test]
    fn format_table_output_handles_mixed_results() {
        let outputs = vec![
            PluginOutput {
                provider_id: "claude".to_string(),
                display_name: "Claude".to_string(),
                plan: Some("Pro".to_string()),
                lines: vec![
                    MetricLine::Progress {
                        label: "Session".to_string(),
                        used: 45.2,
                        limit: 100.0,
                        format: ProgressFormat::Percent,
                        resets_at: Some("2026-02-20T12:00:00Z".to_string()),
                        period_duration_ms: Some(5 * 60 * 60 * 1000),
                        color: None,
                    },
                    MetricLine::Progress {
                        label: "Weekly".to_string(),
                        used: 62.0,
                        limit: 100.0,
                        format: ProgressFormat::Percent,
                        resets_at: Some("2026-02-23T00:00:00Z".to_string()),
                        period_duration_ms: Some(7 * 24 * 60 * 60 * 1000),
                        color: None,
                    },
                ],
                icon_url: String::new(),
            },
            PluginOutput {
                provider_id: "codex".to_string(),
                display_name: "Codex".to_string(),
                plan: None,
                lines: vec![MetricLine::Badge {
                    label: "Error".to_string(),
                    text: "Not logged in".to_string(),
                    color: Some("#ef4444".to_string()),
                    subtitle: None,
                }],
                icon_url: String::new(),
            },
        ];

        let text = format_table_output(outputs).expect("format should succeed");
        assert!(text.contains("Provider"));
        assert!(text.contains("Claude"));
        assert!(text.contains("Pro"));
        assert!(text.contains("45.2%"));
        assert!(text.contains("62%"));
        assert!(text.contains("Codex"));
        assert!(text.contains("N/A"));
    }

    #[test]
    fn truncate_long_names() {
        assert_eq!(truncate("VeryLongProviderName", 11), "VeryLongPr…");
        assert_eq!(truncate("Short", 11), "Short");
        assert_eq!(truncate("ExactlyElev", 11), "ExactlyElev");
    }

    #[test]
    fn has_error_detects_error_badges() {
        let lines_with_error = vec![MetricLine::Badge {
            label: "Error".to_string(),
            text: "Not logged in".to_string(),
            color: Some("#ef4444".to_string()),
            subtitle: None,
        }];
        assert!(has_error(&lines_with_error));

        let lines_without_error = vec![MetricLine::Progress {
            label: "Session".to_string(),
            used: 45.2,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: Some("2026-02-20T12:00:00Z".to_string()),
            period_duration_ms: Some(5 * 60 * 60 * 1000),
            color: None,
        }];
        assert!(!has_error(&lines_without_error));
    }

    #[test]
    fn extract_plan_returns_na_on_error() {
        let output = PluginOutput {
            provider_id: "test".to_string(),
            display_name: "Test".to_string(),
            plan: Some("Pro".to_string()),
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "Failed".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        };
        assert_eq!(extract_plan(&output), "N/A");
    }

    #[test]
    fn extract_session_returns_na_on_error() {
        let output = PluginOutput {
            provider_id: "test".to_string(),
            display_name: "Test".to_string(),
            plan: None,
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "Failed".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        };
        assert_eq!(extract_session(&output), "N/A");
    }
}
