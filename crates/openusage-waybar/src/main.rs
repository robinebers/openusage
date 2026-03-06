use openusage_plugin_engine::manifest::LoadedPlugin;
use openusage_plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Serialize)]
struct WaybarOutput {
    text: String,
    tooltip: String,
    class: String,
    percentage: u8,
}

fn find_plugins_dir() -> Option<PathBuf> {
    // 1. OPENUSAGE_PLUGINS_DIR env var
    if let Ok(dir) = std::env::var("OPENUSAGE_PLUGINS_DIR") {
        let path = PathBuf::from(dir);
        if path.is_dir() {
            return Some(path);
        }
    }

    // 2. XDG data dir: ~/.local/share/openusage/plugins
    if let Some(data_dir) = dirs::data_dir() {
        let path = data_dir.join("openusage").join("plugins");
        if path.is_dir() {
            return Some(path);
        }
    }

    // 3. ~/.config/openusage/plugins
    if let Some(config_dir) = dirs::config_dir() {
        let path = config_dir.join("openusage").join("plugins");
        if path.is_dir() {
            return Some(path);
        }
    }

    // 4. Development: ./plugins or ../plugins relative to cwd
    if let Ok(cwd) = std::env::current_dir() {
        let direct = cwd.join("plugins");
        if direct.is_dir() {
            return Some(direct);
        }
        let parent = cwd.join("..").join("plugins");
        if parent.is_dir() {
            return Some(parent);
        }
    }

    None
}

fn app_data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("OPENUSAGE_DATA_DIR") {
        return PathBuf::from(dir);
    }
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("openusage")
}


fn used_percentage(used: f64, limit: f64) -> u8 {
    if limit <= 0.0 {
        return 0;
    }
    let pct = (used / limit * 100.0).round() as u8;
    pct.min(100)
}


fn severity_class(pct: u8) -> &'static str {
    if pct >= 90 {
        "critical"
    } else if pct >= 75 {
        "warning"
    } else {
        "normal"
    }
}

fn severity_color(pct: u8) -> &'static str {
    if pct >= 90 {
        "#ef4444"
    } else if pct >= 75 {
        "#eab308"
    } else {
        "#22c55e"
    }
}

fn build_progress_bar(used_pct: u8) -> String {
    let total_chars = 20;
    let remaining_pct = 100u8.saturating_sub(used_pct);
    let filled = if remaining_pct > 0 {
        ((remaining_pct as usize * total_chars) / 100).max(1)
    } else {
        0
    };
    let empty = total_chars - filled;
    let color = severity_color(used_pct);
    let filled_str: String = "█".repeat(filled);
    let empty_str: String = "█".repeat(empty);
    format!(
        "<span foreground=\"{color}\">{filled_str}</span><span foreground=\"#4b5563\">{empty_str}</span>"
    )
}

fn format_resets_in(resets_at: &str) -> Option<String> {
    use time::format_description::well_known::Iso8601;
    use time::OffsetDateTime;

    let target = OffsetDateTime::parse(resets_at, &Iso8601::DEFAULT).ok()?;
    let now = OffsetDateTime::now_utc();
    let dur = target - now;

    if dur.is_negative() {
        return Some("Expired".to_string());
    }

    let total_secs = dur.whole_seconds();
    let days = total_secs / 86400;
    let hours = (total_secs % 86400) / 3600;
    let mins = (total_secs % 3600) / 60;

    if days > 0 {
        Some(format!("Resets in {}d {}h", days, hours))
    } else if hours > 0 {
        Some(format!("Resets in {}h {}m", hours, mins))
    } else {
        Some(format!("Resets in {}m", mins))
    }
}

fn format_remaining(used: f64, limit: f64, format: &ProgressFormat) -> String {
    let remaining = (limit - used).max(0.0);
    match format {
        ProgressFormat::Percent => {
            let pct = if limit > 0.0 { (remaining / limit * 100.0).round() } else { 0.0 };
            format!("{:.0}% left", pct)
        }
        ProgressFormat::Dollars => {
            format!("${:.2} left", remaining)
        }
        ProgressFormat::Count { suffix } => {
            format!("{:.0} {} left", remaining, pango_escape(suffix))
        }
    }
}

struct ProgressInfo {
    provider: String,
    pct: u8,
}

fn extract_primary_progress(
    plugin: &LoadedPlugin,
    output: &PluginOutput,
) -> Option<ProgressInfo> {
    // Build ordered list of primary candidate labels from manifest
    let mut candidates: Vec<_> = plugin
        .manifest
        .lines
        .iter()
        .filter(|l| l.line_type == "progress" && l.primary_order.is_some())
        .collect();
    candidates.sort_by_key(|l| l.primary_order.unwrap());

    // Try each candidate in primaryOrder, then fall back to first progress line
    for candidate in &candidates {
        for line in &output.lines {
            if let MetricLine::Progress { label, used, limit, .. } = line {
                if label == &candidate.label {
                    let pct = used_percentage(*used, *limit);
                    return Some(ProgressInfo {
                        provider: output.display_name.clone(),
                        pct,
                    });
                }
            }
        }
    }

    // Fallback: first progress line
    for line in &output.lines {
        if let MetricLine::Progress { used, limit, .. } = line {
            let pct = used_percentage(*used, *limit);
            return Some(ProgressInfo {
                provider: output.display_name.clone(),
                pct,
            });
        }
    }
    None
}

fn pango_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn build_tooltip_for_output(output: &PluginOutput) -> String {
    let mut parts: Vec<String> = Vec::new();

    // Header: provider name + plan badge
    let name = pango_escape(&output.display_name);
    let header = if let Some(plan) = &output.plan {
        let plan = pango_escape(plan);
        format!(
            "<b>{name}</b>  <span bgcolor=\"#374151\" fgcolor=\"#e5e7eb\"> {plan} </span>",
        )
    } else {
        format!("<b>{name}</b>")
    };
    parts.push(header);

    for line in &output.lines {
        match line {
            MetricLine::Progress { label, used, limit, format, resets_at, .. } => {
                let label = pango_escape(label);
                let pct = used_percentage(*used, *limit);
                let color = severity_color(pct);
                let dot = format!("<span foreground=\"{color}\">●</span>");
                let bar = build_progress_bar(pct);
                let remaining = format_remaining(*used, *limit, format);
                let resets = resets_at
                    .as_deref()
                    .and_then(format_resets_in)
                    .unwrap_or_default();

                parts.push(format!("<b>{label}</b> {dot}"));
                parts.push(bar);
                if resets.is_empty() {
                    parts.push(remaining);
                } else {
                    parts.push(format!("{remaining}    {resets}"));
                }
            }
            MetricLine::Text { label, value, .. } => {
                let label = pango_escape(label);
                let value = pango_escape(value);
                parts.push(format!("{label}: {value}"));
            }
            MetricLine::Badge { label, text, .. } => {
                let label = pango_escape(label);
                let text = pango_escape(text);
                parts.push(format!("{label}: {text}"));
            }
        }
    }

    parts.join("\n")
}

fn run_plugins(plugins: &[LoadedPlugin], app_data: &PathBuf) -> Vec<PluginOutput> {
    let version = env!("CARGO_PKG_VERSION");
    plugins
        .iter()
        .map(|plugin| openusage_plugin_engine::runtime::run_probe(plugin, app_data, version))
        .collect()
}

fn parse_args() -> Vec<String> {
    std::env::args().skip(1).collect()
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn"))
        .format_timestamp(None)
        .init();

    let args = parse_args();

    if args.iter().any(|a| a == "--help" || a == "-h") {
        eprintln!("Usage: openusage-waybar [OPTIONS] [PLUGIN_ID...]");
        eprintln!();
        eprintln!("Runs OpenUsage plugins and outputs waybar-compatible JSON.");
        eprintln!();
        eprintln!("Arguments:");
        eprintln!("  [PLUGIN_ID...]  Plugin IDs to run (default: all)");
        eprintln!();
        eprintln!("Options:");
        eprintln!("  --list          List available plugins and exit");
        eprintln!("  --json          Output full plugin results as JSON");
        eprintln!("  -h, --help      Show this help");
        eprintln!();
        eprintln!("Environment:");
        eprintln!("  OPENUSAGE_PLUGINS_DIR  Path to plugins directory");
        eprintln!("  OPENUSAGE_DATA_DIR     Path to app data directory");
        eprintln!("  RUST_LOG               Log level (default: warn)");
        eprintln!();
        eprintln!("Waybar config example:");
        eprintln!("  \"custom/openusage\": {{");
        eprintln!("    \"exec\": \"openusage-waybar claude\",");
        eprintln!("    \"return-type\": \"json\",");
        eprintln!("    \"interval\": 300");
        eprintln!("  }}");
        std::process::exit(0);
    }

    let plugins_dir = match find_plugins_dir() {
        Some(dir) => dir,
        None => {
            let output = WaybarOutput {
                text: "no plugins".to_string(),
                tooltip: "OpenUsage: plugins directory not found.\nSet OPENUSAGE_PLUGINS_DIR or place plugins in ~/.local/share/openusage/plugins/".to_string(),
                class: "critical".to_string(),
                percentage: 0,
            };
            println!("{}", serde_json::to_string(&output).unwrap());
            std::process::exit(0);
        }
    };

    log::info!("plugins dir: {}", plugins_dir.display());

    let all_plugins = openusage_plugin_engine::load_plugins_from_dir(&plugins_dir);

    if args.iter().any(|a| a == "--list") {
        for plugin in &all_plugins {
            println!("{} ({})", plugin.manifest.id, plugin.manifest.name);
        }
        std::process::exit(0);
    }

    let plugin_ids: Vec<&str> = args
        .iter()
        .filter(|a| !a.starts_with('-'))
        .map(|s| s.as_str())
        .collect();

    let selected: Vec<LoadedPlugin> = if plugin_ids.is_empty() {
        all_plugins
    } else {
        all_plugins
            .into_iter()
            .filter(|p| plugin_ids.contains(&p.manifest.id.as_str()))
            .collect()
    };

    if selected.is_empty() {
        let output = WaybarOutput {
            text: "no plugins".to_string(),
            tooltip: "OpenUsage: no matching plugins found".to_string(),
            class: "critical".to_string(),
            percentage: 0,
        };
        println!("{}", serde_json::to_string(&output).unwrap());
        std::process::exit(0);
    }

    let app_data = app_data_dir();
    let _ = std::fs::create_dir_all(&app_data);

    let full_json = args.iter().any(|a| a == "--json");

    let outputs = run_plugins(&selected, &app_data);

    if full_json {
        println!("{}", serde_json::to_string(&outputs).unwrap());
        std::process::exit(0);
    }

    // Build waybar output
    let mut primary_progress: Vec<ProgressInfo> = Vec::new();
    let mut tooltip_sections: Vec<String> = Vec::new();

    for (plugin, output) in selected.iter().zip(outputs.iter()) {
        if let Some(info) = extract_primary_progress(plugin, output) {
            primary_progress.push(info);
        }
        tooltip_sections.push(build_tooltip_for_output(output));
    }

    let (text, pct, class) = if primary_progress.is_empty() {
        let has_errors = outputs.iter().any(|o| {
            o.lines.iter().any(|l| matches!(l, MetricLine::Badge { label, .. } if label == "Error"))
        });
        if has_errors {
            ("err".to_string(), 0u8, "critical")
        } else {
            ("ok".to_string(), 0u8, "normal")
        }
    } else if primary_progress.len() == 1 {
        let info = &primary_progress[0];
        let remaining = 100u8.saturating_sub(info.pct);
        let text = format!("{} {}%", info.provider, remaining);
        (text, info.pct, severity_class(info.pct))
    } else {
        // Multiple providers: show the one with highest usage percentage
        let worst = primary_progress.iter().max_by_key(|p| p.pct).unwrap();
        let remaining = 100u8.saturating_sub(worst.pct);
        let text = format!("{} {}%", worst.provider, remaining);
        (text, worst.pct, severity_class(worst.pct))
    };

    let tooltip = tooltip_sections.join("\n\n");

    let output = WaybarOutput {
        text,
        tooltip,
        class: class.to_string(),
        percentage: 100u8.saturating_sub(pct),
    };

    println!("{}", serde_json::to_string(&output).unwrap());
}
