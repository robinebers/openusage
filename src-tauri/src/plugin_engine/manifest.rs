use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestLine {
    #[serde(rename = "type")]
    pub line_type: String,
    pub label: String,
    pub scope: String,
    /// Lower number = higher priority for primary metric selection.
    /// Only progress lines with primary_order are candidates.
    pub primary_order: Option<u32>,
}

/// Supported operating systems for a plugin
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SupportedOs {
    Macos,
    Windows,
    Linux,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginLink {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginManifest {
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub entry: String,
    pub icon: String,
    pub brand_color: Option<String>,
    pub lines: Vec<ManifestLine>,
    /// List of supported operating systems. If not specified, all platforms are supported.
    pub os: Option<Vec<SupportedOs>>,
    #[serde(default)]
    pub links: Vec<PluginLink>,
}

#[derive(Debug, Clone)]
pub struct LoadedPlugin {
    pub manifest: PluginManifest,
    pub plugin_dir: PathBuf,
    pub entry_script: String,
    pub icon_data_url: String,
}

pub fn load_plugins_from_dir(plugins_dir: &std::path::Path) -> Vec<LoadedPlugin> {
    let mut plugins = Vec::new();
    let entries = match std::fs::read_dir(plugins_dir) {
        Ok(e) => e,
        Err(_) => return plugins,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest_path = path.join("plugin.json");
        if !manifest_path.exists() {
            continue;
        }
        if let Ok(p) = load_single_plugin(&path) {
            plugins.push(p);
        }
    }

    plugins.sort_by(|a, b| a.manifest.id.cmp(&b.manifest.id));
    plugins
}

fn load_single_plugin(
    plugin_dir: &std::path::Path,
) -> Result<LoadedPlugin, Box<dyn std::error::Error>> {
    let manifest_path = plugin_dir.join("plugin.json");
    let manifest_text = std::fs::read_to_string(&manifest_path)?;
    let mut manifest: PluginManifest = serde_json::from_str(&manifest_text)?;
    manifest.links = sanitize_plugin_links(&manifest.id, std::mem::take(&mut manifest.links));

    // Validate primary_order: only progress lines can have it
    for line in manifest.lines.iter() {
        if line.primary_order.is_some() && line.line_type != "progress" {
            log::warn!(
                "plugin {} line '{}' has primaryOrder but type is '{}'; will be ignored",
                manifest.id,
                line.label,
                line.line_type
            );
        }
    }

    if manifest.entry.trim().is_empty() {
        return Err("plugin entry field cannot be empty".into());
    }
    if Path::new(&manifest.entry).is_absolute() {
        return Err("plugin entry must be a relative path".into());
    }

    let entry_path = plugin_dir.join(&manifest.entry);
    let canonical_plugin_dir = plugin_dir.canonicalize()?;
    let canonical_entry_path = entry_path.canonicalize()?;
    if !canonical_entry_path.starts_with(&canonical_plugin_dir) {
        return Err("plugin entry must remain within plugin directory".into());
    }
    if !canonical_entry_path.is_file() {
        return Err("plugin entry must be a file".into());
    }

    let entry_script = std::fs::read_to_string(&canonical_entry_path)?;

    let icon_file = plugin_dir.join(&manifest.icon);
    let icon_bytes = std::fs::read(&icon_file)?;
    let icon_data_url = format!("data:image/svg+xml;base64,{}", STANDARD.encode(&icon_bytes));

    Ok(LoadedPlugin {
        manifest,
        plugin_dir: plugin_dir.to_path_buf(),
        entry_script,
        icon_data_url,
    })
}

fn sanitize_plugin_links(plugin_id: &str, links: Vec<PluginLink>) -> Vec<PluginLink> {
    links
        .into_iter()
        .filter_map(|link| {
            let label = link.label.trim().to_string();
            let url = link.url.trim().to_string();

            if label.is_empty() || url.is_empty() {
                log::warn!(
                    "plugin {} has link with empty label/url; skipping",
                    plugin_id
                );
                return None;
            }
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                log::warn!(
                    "plugin {} link '{}' has non-http(s) url '{}'; skipping",
                    plugin_id,
                    label,
                    url
                );
                return None;
            }

            Some(PluginLink { label, url })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_manifest(json: &str) -> PluginManifest {
        serde_json::from_str::<PluginManifest>(json).expect("manifest parse failed")
    }

    #[test]
    fn primary_order_is_none_by_default() {
        let manifest = parse_manifest(
            r#"
            {
              "schemaVersion": 1,
              "id": "x",
              "name": "X",
              "version": "0.0.1",
              "entry": "plugin.js",
              "icon": "icon.svg",
              "brandColor": null,
              "lines": [
                { "type": "progress", "label": "A", "scope": "overview" }
              ]
            }
            "#,
        );
        assert_eq!(manifest.lines.len(), 1);
        assert!(manifest.lines[0].primary_order.is_none());
        assert!(manifest.links.is_empty());
    }

    #[test]
    fn primary_order_parsed_correctly() {
        let manifest = parse_manifest(
            r#"
            {
              "schemaVersion": 1,
              "id": "x",
              "name": "X",
              "version": "0.0.1",
              "entry": "plugin.js",
              "icon": "icon.svg",
              "brandColor": null,
              "lines": [
                { "type": "progress", "label": "A", "scope": "overview", "primaryOrder": 1 },
                { "type": "progress", "label": "B", "scope": "overview", "primaryOrder": 2 },
                { "type": "progress", "label": "C", "scope": "overview" }
              ]
            }
            "#,
        );

        assert_eq!(manifest.lines[0].primary_order, Some(1));
        assert_eq!(manifest.lines[1].primary_order, Some(2));
        assert!(manifest.lines[2].primary_order.is_none());
    }

    #[test]
    fn primary_candidates_sorted_by_order() {
        let manifest = parse_manifest(
            r#"
            {
              "schemaVersion": 1,
              "id": "x",
              "name": "X",
              "version": "0.0.1",
              "entry": "plugin.js",
              "icon": "icon.svg",
              "brandColor": null,
              "lines": [
                { "type": "progress", "label": "Third", "scope": "overview", "primaryOrder": 3 },
                { "type": "progress", "label": "First", "scope": "overview", "primaryOrder": 1 },
                { "type": "progress", "label": "Second", "scope": "overview", "primaryOrder": 2 },
                { "type": "progress", "label": "None", "scope": "overview" }
              ]
            }
            "#,
        );

        // Extract candidates sorted by primary_order (same logic as lib.rs)
        let mut candidates: Vec<_> = manifest
            .lines
            .iter()
            .filter(|l| l.line_type == "progress" && l.primary_order.is_some())
            .collect();
        candidates.sort_by_key(|l| l.primary_order.unwrap());
        let labels: Vec<_> = candidates.iter().map(|l| l.label.as_str()).collect();

        assert_eq!(labels, vec!["First", "Second", "Third"]);
    }

    #[test]
    fn links_are_parsed_when_present() {
        let manifest = parse_manifest(
            r#"
            {
              "schemaVersion": 1,
              "id": "x",
              "name": "X",
              "version": "0.0.1",
              "entry": "plugin.js",
              "icon": "icon.svg",
              "brandColor": null,
              "links": [
                { "label": "Status", "url": "https://status.example.com" },
                { "label": "Billing", "url": "https://example.com/billing" }
              ],
              "lines": [
                { "type": "progress", "label": "A", "scope": "overview", "primaryOrder": 1 }
              ]
            }
            "#,
        );

        assert_eq!(manifest.links.len(), 2);
        assert_eq!(manifest.links[0].label, "Status");
        assert_eq!(manifest.links[1].url, "https://example.com/billing");
    }

    #[test]
    fn sanitize_plugin_links_filters_invalid_entries() {
        let links = vec![
            PluginLink {
                label: " Status ".to_string(),
                url: " https://status.example.com ".to_string(),
            },
            PluginLink {
                label: " ".to_string(),
                url: "https://example.com".to_string(),
            },
            PluginLink {
                label: "Docs".to_string(),
                url: "ftp://example.com".to_string(),
            },
        ];

        let sanitized = sanitize_plugin_links("x", links);
        assert_eq!(sanitized.len(), 1);
        assert_eq!(sanitized[0].label, "Status");
        assert_eq!(sanitized[0].url, "https://status.example.com");
    }
}
