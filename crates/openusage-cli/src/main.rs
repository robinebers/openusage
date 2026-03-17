mod config;
mod format_table;
mod format_json;
mod setup;
pub mod terminal;

use clap::{Parser, Subcommand};
use openusage_plugin_engine::{manifest, runtime};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;
use terminal::Terminal;

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
    #[command(subcommand)]
    command: Option<Commands>,

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

#[derive(Subcommand)]
enum Commands {
    /// Run interactive setup to configure providers
    Setup,
    /// Add a provider to your configuration
    Add {
        /// Provider ID to add
        provider: String,
    },
    /// Remove a provider from your configuration
    Remove {
        /// Provider ID to remove
        provider: String,
    },
    /// List currently configured providers
    List,
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

    let data_dir = cli.data_dir.clone().unwrap_or_else(default_data_dir);
    if let Err(e) = std::fs::create_dir_all(&data_dir) {
        log::warn!("failed to create data dir: {}", e);
    }

    match &cli.command {
        Some(Commands::Setup) => cmd_setup(&cli, &data_dir),
        Some(Commands::Add { provider }) => cmd_add(&cli, &data_dir, provider),
        Some(Commands::Remove { provider }) => cmd_remove(provider),
        Some(Commands::List) => cmd_list(&cli),
        None => cmd_default(&cli, &data_dir),
    }
}

fn load_plugins_or_exit(plugins_dir: &PathBuf) -> Vec<manifest::LoadedPlugin> {
    if !plugins_dir.exists() {
        eprintln!("error: plugins directory not found: {}", plugins_dir.display());
        std::process::exit(1);
    }

    let plugins = manifest::load_plugins_from_dir(plugins_dir);
    if plugins.is_empty() {
        eprintln!("no plugins found in {}", plugins_dir.display());
        std::process::exit(1);
    }
    plugins
}

fn cmd_setup(cli: &Cli, data_dir: &PathBuf) {
    let plugins = load_plugins_or_exit(&cli.plugins_dir);
    let config_base = config::config_dir();
    let mut terminal = terminal::CrosstermTerminal::new();

    let settings = config::load_settings_from(&config_base);
    if settings.is_some() {
        terminal.println("WARNING: This will REPLACE your current provider list, not append to it.");
        if let Some(s) = &settings {
            if !s.providers.is_empty() {
                terminal.println(&format!("Current providers: {}", s.providers.join(", ")));
            }
        }
        let cont = terminal.confirm("Continue?", false).unwrap_or(false);
        if !cont {
            return;
        }
    }

    let version = env!("CARGO_PKG_VERSION");
    let configured = setup::run_setup(&mut terminal, &plugins, data_dir, &config_base, version);

    let new_settings = config::Settings {
        providers: configured,
    };
    if let Err(e) = config::save_settings_to(&new_settings, &config_base) {
        eprintln!("error: failed to save settings: {}", e);
        std::process::exit(1);
    }
}

fn cmd_add(cli: &Cli, data_dir: &PathBuf, provider_id: &str) {
    let plugins = load_plugins_or_exit(&cli.plugins_dir);
    let config_base = config::config_dir();

    let plugin = match plugins.iter().find(|p| p.manifest.id == provider_id) {
        Some(p) => p,
        None => {
            eprintln!("error: provider '{}' not found", provider_id);
            std::process::exit(1);
        }
    };

    let settings = config::load_settings_from(&config_base).unwrap_or_default();
    if settings.providers.contains(&provider_id.to_string()) {
        println!("Provider '{}' is already configured.", provider_id);
        return;
    }

    let mut terminal = terminal::CrosstermTerminal::new();
    let version = env!("CARGO_PKG_VERSION");

    if setup::setup_provider(&mut terminal, plugin, data_dir, &config_base, version) {
        if let Err(e) = config::add_provider_to(provider_id, &config_base) {
            eprintln!("error: failed to save settings: {}", e);
            std::process::exit(1);
        }
        println!("Provider '{}' added successfully.", provider_id);
    }
}

fn cmd_remove(provider_id: &str) {
    let config_base = config::config_dir();
    match config::remove_provider_from(provider_id, &config_base) {
        Ok(true) => println!("Removed '{}' from configured providers.", provider_id),
        Ok(false) => println!("Provider '{}' is not in your configured providers.", provider_id),
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    }
}

fn cmd_list(cli: &Cli) {
    let config_base = config::config_dir();
    let settings = match config::load_settings_from(&config_base) {
        Some(s) => s,
        None => {
            println!("No providers configured. Run `openusage setup` to get started.");
            return;
        }
    };

    if settings.providers.is_empty() {
        println!("No providers configured. Run `openusage setup` to get started.");
        return;
    }

    // Load plugins for display name lookup
    let plugins = if cli.plugins_dir.exists() {
        manifest::load_plugins_from_dir(&cli.plugins_dir)
    } else {
        vec![]
    };

    for id in &settings.providers {
        let display_name = plugins
            .iter()
            .find(|p| &p.manifest.id == id)
            .map(|p| p.manifest.name.as_str())
            .unwrap_or(id.as_str());
        println!("{}\t{}", id, display_name);
    }
}

fn cmd_default(cli: &Cli, data_dir: &PathBuf) {
    let config_base = config::config_dir();
    let settings = config::load_settings_from(&config_base);

    // First-run detection
    if settings.is_none() {
        if std::io::IsTerminal::is_terminal(&std::io::stdout()) {
            // TTY: trigger first-run setup (no replace warning)
            let plugins = load_plugins_or_exit(&cli.plugins_dir);
            let mut terminal = terminal::CrosstermTerminal::new();
            let version = env!("CARGO_PKG_VERSION");
            let configured = setup::run_setup(&mut terminal, &plugins, data_dir, &config_base, version);

            let new_settings = config::Settings {
                providers: configured,
            };
            if let Err(e) = config::save_settings_to(&new_settings, &config_base) {
                eprintln!("error: failed to save settings: {}", e);
                std::process::exit(1);
            }
            // After setup, continue with the default probe flow using the new settings
            return cmd_probe(cli, data_dir, &Some(new_settings));
        } else {
            eprintln!("No providers configured. Run `openusage setup` first.");
            std::process::exit(1);
        }
    }

    cmd_probe(cli, data_dir, &settings);
}

const SPINNER_FRAMES: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

fn cmd_probe(cli: &Cli, data_dir: &PathBuf, settings: &Option<config::Settings>) {
    let plugins = load_plugins_or_exit(&cli.plugins_dir);
    let config_base = config::config_dir();

    let mut errors: HashMap<String, ProviderError> = HashMap::new();

    // Determine which providers to probe
    let selected: Vec<_> = if !cli.providers.is_empty() {
        // --provider flag overrides settings
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
    } else if let Some(s) = settings {
        // Use settings provider list
        plugins
            .into_iter()
            .filter(|p| s.providers.contains(&p.manifest.id))
            .collect()
    } else {
        // No settings, no --provider flag: use all plugins
        plugins
    };

    if selected.is_empty() && errors.is_empty() {
        eprintln!("no matching providers found");
        std::process::exit(1);
    }

    // Inject env keys for all selected providers before probing
    for plugin in &selected {
        if let Some(cli_meta) = &plugin.manifest.cli {
            let env_var_names = cli_meta.env_var_names.as_deref().unwrap_or(&[]);
            config::inject_env_keys_from(&plugin.manifest.id, env_var_names, &config_base);
        }
    }

    let show_spinner = !cli.json && std::io::IsTerminal::is_terminal(&std::io::stderr());

    // Build display name lookup for spinner
    let provider_names: Vec<(String, String)> = selected
        .iter()
        .map(|p| (p.manifest.id.clone(), p.manifest.name.clone()))
        .collect();

    let version = env!("CARGO_PKG_VERSION");

    let outputs: Vec<runtime::PluginOutput> = if show_spinner {
        probe_with_spinner(&selected, data_dir, version, &provider_names)
    } else {
        // Silent mode: --json or non-TTY
        std::thread::scope(|s| {
            let handles: Vec<_> = selected
                .iter()
                .map(|plugin| {
                    let data = data_dir;
                    s.spawn(move || runtime::run_probe(plugin, &data.to_path_buf(), version))
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        })
    };

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

fn probe_with_spinner(
    selected: &[manifest::LoadedPlugin],
    data_dir: &PathBuf,
    version: &str,
    provider_names: &[(String, String)],
) -> Vec<runtime::PluginOutput> {
    use crossterm::{cursor, execute, style::Print, terminal as ct};
    use std::io::Write;

    let count = selected.len();
    let mut stderr = std::io::stderr();

    // Print initial spinner lines
    for (_id, name) in provider_names {
        let _ = execute!(stderr, Print(format!("{} {}\n", SPINNER_FRAMES[0], name)));
    }
    let _ = stderr.flush();

    // Track completion state per provider
    let mut completed: Vec<Option<bool>> = vec![None; count]; // None=pending, Some(true)=ok, Some(false)=error
    let mut results: Vec<Option<runtime::PluginOutput>> = (0..count).map(|_| None).collect();

    // Spawn probes with channel
    let (tx, rx) = mpsc::channel::<(usize, runtime::PluginOutput)>();

    std::thread::scope(|s| {
        for (i, plugin) in selected.iter().enumerate() {
            let tx = tx.clone();
            let data = data_dir.clone();
            let ver = version.to_string();
            s.spawn(move || {
                let output = runtime::run_probe(plugin, &data, &ver);
                let _ = tx.send((i, output));
            });
        }
        drop(tx); // Close sender so rx will terminate

        let mut frame = 0usize;
        let mut done_count = 0;

        while done_count < count {
            // Try to receive results (non-blocking with short timeout for animation)
            match rx.recv_timeout(Duration::from_millis(80)) {
                Ok((idx, output)) => {
                    let is_ok = !is_error_only(&output);
                    completed[idx] = Some(is_ok);
                    results[idx] = Some(output);
                    done_count += 1;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }

            // Redraw all lines
            frame = (frame + 1) % SPINNER_FRAMES.len();
            let _ = execute!(stderr, cursor::MoveUp(count as u16));
            for (i, (_id, name)) in provider_names.iter().enumerate() {
                let line = match completed[i] {
                    None => format!("\x1b[33m{}\x1b[0m {}", SPINNER_FRAMES[frame], name),
                    Some(true) => format!("\x1b[32m\u{2713}\x1b[0m {}", name),
                    Some(false) => format!("\x1b[31m\u{2717}\x1b[0m {}", name),
                };
                let _ = execute!(
                    stderr,
                    ct::Clear(ct::ClearType::CurrentLine),
                    cursor::MoveToColumn(0),
                    Print(&line),
                    Print("\n"),
                );
            }
            let _ = stderr.flush();
        }

        // Final redraw to ensure all are resolved
        let _ = execute!(stderr, cursor::MoveUp(count as u16));
        for (i, (_id, name)) in provider_names.iter().enumerate() {
            let line = match completed[i] {
                Some(true) => format!("\x1b[32m\u{2713}\x1b[0m {}", name),
                Some(false) => format!("\x1b[31m\u{2717}\x1b[0m {}", name),
                None => format!("? {}", name),
            };
            let _ = execute!(
                stderr,
                ct::Clear(ct::ClearType::CurrentLine),
                cursor::MoveToColumn(0),
                Print(&line),
                Print("\n"),
            );
        }
        let _ = stderr.flush();

        // Clear spinner lines so table output is clean
        let _ = execute!(stderr, cursor::MoveUp(count as u16));
        for _ in 0..count {
            let _ = execute!(
                stderr,
                ct::Clear(ct::ClearType::CurrentLine),
                Print("\n"),
            );
        }
        let _ = execute!(stderr, cursor::MoveUp(count as u16));
        let _ = stderr.flush();
    });

    // Collect results in original order
    results.into_iter().flatten().collect()
}

pub(crate) fn is_error_only(output: &runtime::PluginOutput) -> bool {
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
