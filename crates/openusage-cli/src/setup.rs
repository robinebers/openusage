use crate::config;
use crate::terminal::{Terminal, PickerItem};
use openusage_plugin_engine::manifest::LoadedPlugin;
use openusage_plugin_engine::runtime;
use std::path::Path;

/// Run the full interactive setup flow. Returns list of successfully configured provider IDs.
pub fn run_setup(
    terminal: &mut dyn Terminal,
    plugins: &[LoadedPlugin],
    data_dir: &Path,
    config_base: &Path,
    app_version: &str,
) -> Vec<String> {
    let items: Vec<PickerItem> = plugins
        .iter()
        .filter(|p| {
            let cli = match &p.manifest.cli {
                Some(c) => c,
                None => return false,
            };
            // Exclude demo category and mock plugin
            if cli.category == "demo" || p.manifest.id == "mock" {
                return false;
            }
            true
        })
        .map(|p| {
            let cli = p.manifest.cli.as_ref().unwrap();
            let pre_selected = if cli.category == "cli" {
                cli.binary_name
                    .as_deref()
                    .map(is_binary_installed)
                    .unwrap_or(false)
            } else {
                false
            };
            PickerItem {
                id: p.manifest.id.clone(),
                label: p.manifest.name.clone(),
                selected: pre_selected,
            }
        })
        .collect();

    let selected_ids = match terminal.picker("Select providers to configure:", items) {
        Ok(ids) => ids,
        Err(_) => return vec![],
    };

    let mut configured = Vec::new();
    for id in &selected_ids {
        if let Some(plugin) = plugins.iter().find(|p| &p.manifest.id == id) {
            if setup_provider(terminal, plugin, data_dir, config_base, app_version) {
                configured.push(id.clone());
            }
        }
    }

    configured
}

/// Run setup for a single provider (used by `add` command). Returns true if provider configured successfully.
pub fn setup_provider(
    terminal: &mut dyn Terminal,
    plugin: &LoadedPlugin,
    data_dir: &Path,
    config_base: &Path,
    app_version: &str,
) -> bool {
    let cli = match &plugin.manifest.cli {
        Some(c) => c,
        None => return false,
    };

    let env_var_names = cli.env_var_names.as_deref().unwrap_or(&[]);

    match cli.category.as_str() {
        "cli" => setup_cli_provider(terminal, plugin, data_dir, config_base, app_version, env_var_names),
        "ide" => setup_ide_provider(terminal, plugin, data_dir, config_base, app_version, env_var_names),
        "env" => setup_env_provider(terminal, plugin, data_dir, config_base, app_version, env_var_names, cli),
        "demo" => false, // should never be called
        _ => false,
    }
}

fn setup_cli_provider(
    terminal: &mut dyn Terminal,
    plugin: &LoadedPlugin,
    data_dir: &Path,
    config_base: &Path,
    app_version: &str,
    env_var_names: &[String],
) -> bool {
    let cli = plugin.manifest.cli.as_ref().unwrap();
    let binary_name = cli.binary_name.as_deref().unwrap_or("");

    // Step 1: Check binary
    if !binary_name.is_empty() && !is_binary_installed(binary_name) {
        if let Some(install_cmd) = &cli.install_cmd {
            terminal.println(&format!("Install command: {}", install_cmd));
            let do_install = terminal.confirm("Install now?", true).unwrap_or(false);
            if !do_install {
                return false;
            }
            let status = std::process::Command::new("sh")
                .arg("-c")
                .arg(install_cmd)
                .status();
            match status {
                Ok(s) if s.success() => {}
                _ => {
                    terminal.println("Installation failed.");
                    return false;
                }
            }
        } else {
            terminal.println(&format!(
                "{} binary not found. Install it manually and try again.",
                plugin.manifest.name
            ));
            let _ = terminal.wait_for_enter("Press Enter to continue...");
            return false;
        }
    }

    // Step 2: Binary present, inject keys and check auth
    config::inject_env_keys_from(&plugin.manifest.id, env_var_names, config_base);
    if is_authenticated(plugin, data_dir, app_version) {
        return true;
    }

    // Step 3: Not authenticated
    if let Some(login_cmd) = &cli.login_cmd {
        terminal.println(&format!("Running: {}", login_cmd));
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(login_cmd)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status();
        match status {
            Ok(s) if s.success() => {
                if is_authenticated(plugin, data_dir, app_version) {
                    return true;
                }
                terminal.println("Authentication check failed after login. Debug this on your own.");
                false
            }
            _ => {
                terminal.println("Login command failed.");
                false
            }
        }
    } else {
        terminal.println("Not authenticated. Set up authentication manually and try again.");
        let _ = terminal.wait_for_enter("Press Enter to continue...");
        false
    }
}

fn setup_ide_provider(
    terminal: &mut dyn Terminal,
    plugin: &LoadedPlugin,
    data_dir: &Path,
    config_base: &Path,
    app_version: &str,
    env_var_names: &[String],
) -> bool {
    config::inject_env_keys_from(&plugin.manifest.id, env_var_names, config_base);
    if is_authenticated(plugin, data_dir, app_version) {
        return true;
    }
    terminal.println(&format!(
        "{} IDE not detected or not authenticated on this system.",
        plugin.manifest.name
    ));
    let _ = terminal.wait_for_enter("Press Enter to continue...");
    false
}

fn setup_env_provider(
    terminal: &mut dyn Terminal,
    plugin: &LoadedPlugin,
    data_dir: &Path,
    config_base: &Path,
    app_version: &str,
    env_var_names: &[String],
    cli: &openusage_plugin_engine::manifest::CliMeta,
) -> bool {
    // Step 1: Check if key already exists
    let keys = config::load_keys_from(config_base);
    let has_key = keys.contains_key(&plugin.manifest.id);

    // Also check if env var is already set
    let env_already_set = env_var_names.iter().any(|v| std::env::var(v).is_ok());

    if !has_key && !env_already_set {
        // Step 2: Prompt for key
        let label = cli.env_key_label.as_deref().unwrap_or("API Key");
        let key_value = terminal.input(&format!("Enter {}", label), None).unwrap_or_default();
        if key_value.is_empty() {
            return false;
        }

        // Step 3: Prompt for key name
        let key_name = terminal
            .input("Key name (default)", Some("default"))
            .unwrap_or_default();
        let key_name = if key_name.is_empty() {
            "default".to_string()
        } else {
            key_name
        };

        // Step 4: Save to keys.json
        let mut all_keys = config::load_keys_from(config_base);
        all_keys.insert(
            plugin.manifest.id.clone(),
            config::KeyEntry {
                key: key_value,
                key_name,
            },
        );
        if config::save_keys_to(&all_keys, config_base).is_err() {
            terminal.println("Failed to save key.");
            return false;
        }
    }

    // Step 5: Inject and verify
    config::inject_env_keys_from(&plugin.manifest.id, env_var_names, config_base);
    if is_authenticated(plugin, data_dir, app_version) {
        return true;
    }
    terminal.println("API key verification failed.");
    false
}

/// Check if a binary is available on PATH
pub fn is_binary_installed(name: &str) -> bool {
    std::process::Command::new("which")
        .arg(name)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check if a plugin probe succeeds (not error-only)
fn is_authenticated(plugin: &LoadedPlugin, data_dir: &Path, app_version: &str) -> bool {
    let output = runtime::run_probe(plugin, &data_dir.to_path_buf(), app_version);
    !crate::is_error_only(&output)
}

/// Build picker items from plugins, filtering out demo/mock.
/// Exposed for testing.
pub fn build_picker_items(plugins: &[LoadedPlugin]) -> Vec<PickerItem> {
    plugins
        .iter()
        .filter(|p| {
            let cli = match &p.manifest.cli {
                Some(c) => c,
                None => return false,
            };
            if cli.category == "demo" || p.manifest.id == "mock" {
                return false;
            }
            true
        })
        .map(|p| {
            let cli = p.manifest.cli.as_ref().unwrap();
            let pre_selected = if cli.category == "cli" {
                cli.binary_name
                    .as_deref()
                    .map(is_binary_installed)
                    .unwrap_or(false)
            } else {
                false
            };
            PickerItem {
                id: p.manifest.id.clone(),
                label: p.manifest.name.clone(),
                selected: pre_selected,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::MockTerminal;
    use openusage_plugin_engine::manifest::{CliMeta, PluginManifest};
    use std::path::PathBuf;

    fn make_plugin(id: &str, name: &str, cli: Option<CliMeta>) -> LoadedPlugin {
        LoadedPlugin {
            manifest: PluginManifest {
                schema_version: 1,
                id: id.to_string(),
                name: name.to_string(),
                version: "0.0.1".to_string(),
                entry: "plugin.js".to_string(),
                icon: "icon.svg".to_string(),
                brand_color: None,
                lines: vec![],
                links: vec![],
                cli,
            },
            plugin_dir: PathBuf::from("."),
            entry_script: String::new(),
            icon_data_url: String::new(),
        }
    }

    #[test]
    fn is_binary_installed_finds_ls() {
        assert!(is_binary_installed("ls"));
    }

    #[test]
    fn is_binary_installed_returns_false_for_nonexistent() {
        assert!(!is_binary_installed("nonexistent_binary_xyz_abc_123"));
    }

    #[test]
    fn build_picker_items_excludes_demo_category() {
        let plugins = vec![
            make_plugin(
                "claude",
                "Claude",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: Some("claude".to_string()),
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
            make_plugin(
                "antigravity",
                "Antigravity",
                Some(CliMeta {
                    category: "demo".to_string(),
                    binary_name: None,
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
        ];

        let items = build_picker_items(&plugins);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "claude");
    }

    #[test]
    fn build_picker_items_excludes_mock_plugin() {
        let plugins = vec![
            make_plugin(
                "mock",
                "Mock Provider",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: None,
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
            make_plugin(
                "copilot",
                "GitHub Copilot",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: Some("gh".to_string()),
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
        ];

        let items = build_picker_items(&plugins);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "copilot");
    }

    #[test]
    fn build_picker_items_excludes_plugins_without_cli() {
        let plugins = vec![
            make_plugin("nocli", "No CLI", None),
            make_plugin(
                "withcli",
                "With CLI",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: Some("ls".to_string()),
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
        ];

        let items = build_picker_items(&plugins);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "withcli");
    }

    #[test]
    fn build_picker_items_preselects_installed_cli_binaries() {
        let plugins = vec![
            make_plugin(
                "ls-tool",
                "LS Tool",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: Some("ls".to_string()), // ls always exists
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
            make_plugin(
                "fake-tool",
                "Fake Tool",
                Some(CliMeta {
                    category: "cli".to_string(),
                    binary_name: Some("nonexistent_binary_xyz".to_string()),
                    install_cmd: None,
                    login_cmd: None,
                    env_var_names: None,
                    env_key_label: None,
                }),
            ),
        ];

        let items = build_picker_items(&plugins);
        assert_eq!(items.len(), 2);
        // ls should be pre-selected
        assert!(items.iter().find(|i| i.id == "ls-tool").unwrap().selected);
        // nonexistent should not be pre-selected
        assert!(!items.iter().find(|i| i.id == "fake-tool").unwrap().selected);
    }

    #[test]
    fn build_picker_items_non_cli_categories_not_preselected() {
        let plugins = vec![make_plugin(
            "minimax",
            "MiniMax",
            Some(CliMeta {
                category: "env".to_string(),
                binary_name: None,
                install_cmd: None,
                login_cmd: None,
                env_var_names: Some(vec!["MINIMAX_API_KEY".to_string()]),
                env_key_label: Some("MiniMax API Key".to_string()),
            }),
        )];

        let items = build_picker_items(&plugins);
        assert_eq!(items.len(), 1);
        assert!(!items[0].selected);
    }

    #[test]
    fn run_setup_returns_empty_when_picker_selects_nothing() {
        let mut terminal = MockTerminal::new()
            .with_picker_responses(vec![vec![]]);

        let plugins = vec![make_plugin(
            "claude",
            "Claude",
            Some(CliMeta {
                category: "cli".to_string(),
                binary_name: Some("claude".to_string()),
                install_cmd: None,
                login_cmd: None,
                env_var_names: None,
                env_key_label: None,
            }),
        )];

        let tmp = std::env::temp_dir().join(format!("openusage-test-setup-empty-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let result = run_setup(&mut terminal, &plugins, &tmp, &tmp, "0.0.1");
        assert!(result.is_empty());
    }

    #[test]
    fn setup_provider_returns_false_when_no_cli_meta() {
        let mut terminal = MockTerminal::new();
        let plugin = make_plugin("nocli", "No CLI", None);
        let tmp = std::env::temp_dir().join(format!("openusage-test-nocli-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");
        assert!(!result);
    }

    #[test]
    fn setup_cli_provider_no_binary_no_install_cmd() {
        let mut terminal = MockTerminal::new();
        let plugin = make_plugin(
            "fake",
            "Fake Tool",
            Some(CliMeta {
                category: "cli".to_string(),
                binary_name: Some("nonexistent_binary_xyz_999".to_string()),
                install_cmd: None,
                login_cmd: None,
                env_var_names: None,
                env_key_label: None,
            }),
        );

        let tmp = std::env::temp_dir().join(format!("openusage-test-nobin-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");
        assert!(!result);
        assert!(terminal.printed().iter().any(|m| m.contains("binary not found")));
        assert_eq!(terminal.wait_count(), 1);
    }

    #[test]
    fn setup_cli_provider_with_binary_not_found_and_install_declined() {
        // confirm returns false (decline install)
        let mut terminal = MockTerminal::new()
            .with_confirm_responses(vec![false]);

        let plugin = make_plugin(
            "fake",
            "Fake Tool",
            Some(CliMeta {
                category: "cli".to_string(),
                binary_name: Some("nonexistent_binary_xyz_999".to_string()),
                install_cmd: Some("echo install".to_string()),
                login_cmd: None,
                env_var_names: None,
                env_key_label: None,
            }),
        );

        let tmp = std::env::temp_dir().join(format!("openusage-test-decline-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");
        assert!(!result);
    }

    #[test]
    fn setup_env_provider_empty_key_returns_false() {
        // input returns empty string
        let mut terminal = MockTerminal::new()
            .with_input_responses(vec!["".to_string()]);

        let plugin = make_plugin(
            "minimax",
            "MiniMax",
            Some(CliMeta {
                category: "env".to_string(),
                binary_name: None,
                install_cmd: None,
                login_cmd: None,
                env_var_names: Some(vec!["MINIMAX_TEST_KEY".to_string()]),
                env_key_label: Some("MiniMax API Key".to_string()),
            }),
        );

        let tmp = std::env::temp_dir().join(format!("openusage-test-envempty-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");
        assert!(!result);
    }

    #[test]
    fn setup_env_provider_saves_key_to_config() {
        // input: key value, then key name
        let mut terminal = MockTerminal::new()
            .with_input_responses(vec!["sk-test-123".to_string(), "my-key".to_string()]);

        let plugin = make_plugin(
            "testenv",
            "Test Env",
            Some(CliMeta {
                category: "env".to_string(),
                binary_name: None,
                install_cmd: None,
                login_cmd: None,
                env_var_names: Some(vec!["TEST_ENV_KEY_SETUP".to_string()]),
                env_key_label: Some("Test API Key".to_string()),
            }),
        );

        let tmp = std::env::temp_dir().join(format!("openusage-test-envsave-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        // The probe will fail (no real plugin), so setup_provider returns false,
        // but we can verify the key was saved
        let _result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");

        let keys = config::load_keys_from(&tmp);
        assert!(keys.contains_key("testenv"));
        assert_eq!(keys["testenv"].key, "sk-test-123");
        assert_eq!(keys["testenv"].key_name, "my-key");
    }

    #[test]
    fn setup_env_provider_uses_default_key_name() {
        // input: key value, then empty (should use "default")
        let mut terminal = MockTerminal::new()
            .with_input_responses(vec!["sk-test-456".to_string(), "".to_string()]);

        let plugin = make_plugin(
            "testenv2",
            "Test Env 2",
            Some(CliMeta {
                category: "env".to_string(),
                binary_name: None,
                install_cmd: None,
                login_cmd: None,
                env_var_names: Some(vec!["TEST_ENV_KEY_DEFAULT".to_string()]),
                env_key_label: Some("Test API Key".to_string()),
            }),
        );

        let tmp = std::env::temp_dir().join(format!("openusage-test-envdefault-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let _result = setup_provider(&mut terminal, &plugin, &tmp, &tmp, "0.0.1");

        let keys = config::load_keys_from(&tmp);
        assert!(keys.contains_key("testenv2"));
        assert_eq!(keys["testenv2"].key_name, "default");
    }
}
