use crate::plugin_engine::manifest::{load_plugins_from_dir, LoadedPlugin};
use crate::plugin_engine::runtime::{run_probe, MetricLine, PluginOutput, ProgressFormat};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CliDisplayMode {
    Left,
    Used,
}

#[derive(Debug, PartialEq, Eq)]
enum ParseResult {
    NotCli,
    Help,
    Run {
        provider: Option<String>,
        display_mode: CliDisplayMode,
    },
    Error(String),
}

pub fn run_from_env() -> bool {
    let is_cli_binary = is_cli_named_binary();
    match parse_args(std::env::args().skip(1), is_cli_binary) {
        ParseResult::NotCli => false,
        ParseResult::Help => {
            print_help();
            true
        }
        ParseResult::Run {
            provider: None,
            display_mode,
        } => {
            // Safety: CLI mode is single-threaded here before runtime setup.
            unsafe {
                std::env::set_var("OPENUSAGE_DISABLE_SYSTEM_PROXY", "1");
            }
            match run_all_providers(display_mode) {
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
        ParseResult::Run {
            provider: Some(provider),
            display_mode,
        } => {
            // Safety: CLI mode is single-threaded here before runtime setup.
            unsafe {
                std::env::set_var("OPENUSAGE_DISABLE_SYSTEM_PROXY", "1");
            }

            match run_provider(&provider, display_mode) {
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
        ParseResult::Error(error) => {
            eprintln!("Error: {}", error);
            eprintln!("Usage: openusage-cli --provider=<id>");
            std::process::exit(2);
        }
    }
}

fn is_cli_named_binary() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.file_name().map(|name| name.to_string_lossy().to_string()))
        .map(|name| name.eq_ignore_ascii_case("openusage-cli"))
        .unwrap_or(false)
}

fn parse_args<I>(args: I, force_cli: bool) -> ParseResult
where
    I: IntoIterator<Item = String>,
{
    let mut iter = args.into_iter();
    let mut provider: Option<String> = None;
    let mut display_mode = CliDisplayMode::Left;
    let mut cli_mode = force_cli;
    while let Some(arg) = iter.next() {
        if arg == "--help" || arg == "-h" {
            return ParseResult::Help;
        }

        if arg == "--used" {
            display_mode = CliDisplayMode::Used;
            cli_mode = true;
            continue;
        }

        if let Some(value) = arg.strip_prefix("--provider=") {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                return ParseResult::Error("provider cannot be empty".to_string());
            }
            provider = Some(trimmed.to_string());
            cli_mode = true;
            continue;
        }

        if arg == "--provider" {
            let value = iter.next().unwrap_or_default();
            if value.starts_with("--") || value.trim().is_empty() {
                return ParseResult::Error("--provider requires a value".to_string());
            }
            provider = Some(value.trim().to_string());
            cli_mode = true;
            continue;
        }

        if arg.starts_with("--provider") {
            return ParseResult::Error(format!("invalid --provider argument '{}'", arg));
        }

        if force_cli {
            return ParseResult::Error(format!("unknown argument '{}'", arg));
        }
        return ParseResult::NotCli;
    }

    if cli_mode {
        return ParseResult::Run {
            provider,
            display_mode,
        };
    }

    ParseResult::NotCli
}

fn print_help() {
    println!("OpenUsage CLI");
    println!();
    println!("Usage:");
    println!("  openusage-cli");
    println!("  openusage-cli --provider=<id>");
    println!("  openusage-cli --used");
    println!();
    println!("Example:");
    println!("  openusage-cli");
    println!("  openusage-cli --provider=claude");
    println!("  openusage-cli --provider=claude --used");
}

fn run_provider(provider_id: &str, display_mode: CliDisplayMode) -> Result<String, String> {
    let plugin_dir = resolve_plugins_dir().ok_or_else(|| {
        "could not locate plugins directory. Set OPENUSAGE_PLUGINS_DIR or install desktop app."
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
    format_output(output, display_mode)
}

fn run_all_providers(display_mode: CliDisplayMode) -> Result<String, String> {
    let plugin_dir = resolve_plugins_dir().ok_or_else(|| {
        "could not locate plugins directory. Set OPENUSAGE_PLUGINS_DIR or install desktop app."
            .to_string()
    })?;
    let plugins = load_plugins_from_dir(&plugin_dir);
    if plugins.is_empty() {
        return Err(format!("no plugins found in {}", plugin_dir.display()));
    }

    let app_data_dir = resolve_app_data_dir()?;
    let mut rendered = Vec::new();

    for plugin in &plugins {
        let output = run_probe(plugin, &app_data_dir, env!("CARGO_PKG_VERSION"));
        if let Some(line) = format_summary_line(&output, display_mode) {
            rendered.push(line);
        }
    }

    if rendered.is_empty() {
        return Err("No provider usage data available.".to_string());
    }

    Ok(rendered.join("\n"))
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
    dir.push("com.sunstory.openusage");
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("failed to create app data dir {}: {}", dir.display(), error))?;
    Ok(dir)
}

fn format_output(output: PluginOutput, display_mode: CliDisplayMode) -> Result<String, String> {
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
    out.push_str(&format!(
        "Session: {}\n",
        format_progress_with_mode(session, display_mode)
    ));
    out.push_str(&format!("Session reset: {}\n", format_reset(session)));
    out.push_str(&format!(
        "Weekly: {}\n",
        format_progress_with_mode(weekly, display_mode)
    ));
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

fn format_progress_with_mode(line: Option<&MetricLine>, display_mode: CliDisplayMode) -> String {
    match line {
        Some(MetricLine::Progress {
            used,
            limit,
            format,
            ..
        }) => format_value(*used, *limit, format, display_mode),
        _ => "n/a".to_string(),
    }
}

fn format_reset(line: Option<&MetricLine>) -> String {
    match line {
        Some(MetricLine::Progress {
            resets_at: Some(resets_at),
            ..
        }) if !resets_at.trim().is_empty() => resets_at.trim().to_string(),
        _ => "n/a".to_string(),
    }
}

fn format_value(
    used: f64,
    limit: f64,
    format: &ProgressFormat,
    display_mode: CliDisplayMode,
) -> String {
    if !used.is_finite() || !limit.is_finite() {
        return "n/a".to_string();
    }
    if limit <= 0.0 {
        return "n/a".to_string();
    }
    let display_used = match display_mode {
        CliDisplayMode::Left => (limit - used).max(0.0),
        CliDisplayMode::Used => used,
    };
    match format {
        ProgressFormat::Percent => format!("{:.1}%", (display_used / limit) * 100.0),
        ProgressFormat::Dollars | ProgressFormat::Count { .. } => {
            let left = if display_used.fract() == 0.0 {
                format!("{:.0}", display_used)
            } else {
                format!("{:.1}", display_used)
            };
            let right = if limit.fract() == 0.0 {
                format!("{:.0}", limit)
            } else {
                format!("{:.1}", limit)
            };
            format!("{}/{}", left, right)
        }
    }
}

fn format_summary_line(output: &PluginOutput, display_mode: CliDisplayMode) -> Option<String> {
    if output.lines.iter().any(|line| matches!(
        line,
        MetricLine::Badge { label, .. } if label.eq_ignore_ascii_case("error")
    )) {
        return None;
    }

    let session = progress_percent(find_progress_line(&output.lines, "session"), display_mode)?;
    let weekly = progress_percent(find_progress_line(&output.lines, "weekly"), display_mode)?;
    Some(format!("{}: session {:.1}% | weekly {:.1}%", output.display_name, session, weekly))
}

fn progress_percent(line: Option<&MetricLine>, display_mode: CliDisplayMode) -> Option<f64> {
    match line {
        Some(MetricLine::Progress { used, limit, .. }) if used.is_finite() && limit.is_finite() && *limit > 0.0 => {
            let display_used = match display_mode {
                CliDisplayMode::Left => (*limit - *used).max(0.0),
                CliDisplayMode::Used => *used,
            };
            let ratio = (display_used / *limit) * 100.0;
            Some(ratio.clamp(0.0, 1000.0))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{format_summary_line, parse_args, CliDisplayMode, MetricLine, ParseResult, PluginOutput, ProgressFormat};

    #[test]
    fn parse_help() {
        assert_eq!(parse_args(vec!["--help".to_string()], false), ParseResult::Help);
    }

    #[test]
    fn parse_provider_equals() {
        assert_eq!(
            parse_args(vec!["--provider=claude".to_string()], false),
            ParseResult::Run {
                provider: Some("claude".to_string()),
                display_mode: CliDisplayMode::Left,
            }
        );
    }

    #[test]
    fn parse_provider_space() {
        assert_eq!(
            parse_args(vec!["--provider".to_string(), "codex".to_string()], false),
            ParseResult::Run {
                provider: Some("codex".to_string()),
                display_mode: CliDisplayMode::Left,
            }
        );
    }

    #[test]
    fn parse_no_args_is_not_cli() {
        assert_eq!(parse_args(Vec::<String>::new(), false), ParseResult::NotCli);
    }

    #[test]
    fn parse_no_args_is_help_for_cli_binary() {
        assert_eq!(
            parse_args(Vec::<String>::new(), true),
            ParseResult::Run {
                provider: None,
                display_mode: CliDisplayMode::Left,
            }
        );
    }

    #[test]
    fn parse_unknown_arg_errors_for_cli_binary() {
        assert_eq!(
            parse_args(vec!["--wat".to_string()], true),
            ParseResult::Error("unknown argument '--wat'".to_string())
        );
    }

    #[test]
    fn parse_used_flag() {
        assert_eq!(
            parse_args(vec!["--used".to_string(), "--provider=claude".to_string()], true),
            ParseResult::Run {
                provider: Some("claude".to_string()),
                display_mode: CliDisplayMode::Used,
            }
        );
    }

    #[test]
    fn summary_line_requires_session_and_weekly() {
        let output = PluginOutput {
            provider_id: "p".to_string(),
            display_name: "Provider".to_string(),
            plan: None,
            icon_url: "".to_string(),
            lines: vec![
                MetricLine::Progress {
                    label: "Session".to_string(),
                    used: 50.0,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: None,
                    period_duration_ms: None,
                    color: None,
                },
            ],
        };
        assert!(format_summary_line(&output, CliDisplayMode::Left).is_none());
    }

    #[test]
    fn summary_line_skips_errors() {
        let output = PluginOutput {
            provider_id: "p".to_string(),
            display_name: "Provider".to_string(),
            plan: None,
            icon_url: "".to_string(),
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "nope".to_string(),
                color: None,
                subtitle: None,
            }],
        };
        assert!(format_summary_line(&output, CliDisplayMode::Left).is_none());
    }
}
