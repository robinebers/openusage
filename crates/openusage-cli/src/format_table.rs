use crate::ProviderError;
use openusage_plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};
use std::collections::HashMap;

const BAR_WIDTH: usize = 10;
const FULL_BLOCK: char = '\u{2588}';
const LIGHT_SHADE: char = '\u{2591}';

pub fn format(outputs: &[PluginOutput], errors: &HashMap<String, ProviderError>) -> String {
    let mut out = String::new();

    if !outputs.is_empty() {
        let rows = build_rows(outputs);
        out.push_str(&render_table(&rows));
    }

    if !errors.is_empty() {
        out.push_str("Logs\n");
        let mut sorted_errors: Vec<_> = errors.iter().collect();
        sorted_errors.sort_by_key(|(k, _)| (*k).clone());
        for (provider_id, error) in sorted_errors {
            out.push_str(&format!(
                "  [{}] {}: {}\n",
                error.code, provider_id, error.message
            ));
        }
    }

    out
}

struct Row {
    provider: String,
    plan: String,
    metric: String,
    usage: String,
    separator_before: bool,
}

fn build_rows(outputs: &[PluginOutput]) -> Vec<Row> {
    let mut rows = Vec::new();
    for (idx, output) in outputs.iter().enumerate() {
        let mut first = true;
        for line in &output.lines {
            let provider = if first { output.display_name.clone() } else { String::new() };
            let plan = if first {
                output.plan.clone().unwrap_or_default()
            } else {
                String::new()
            };
            let separator_before = first && idx > 0;
            first = false;

            let (metric, usage) = format_line(line);
            rows.push(Row { provider, plan, metric, usage, separator_before });
        }
    }
    rows
}

fn format_line(line: &MetricLine) -> (String, String) {
    match line {
        MetricLine::Progress { label, used, limit, format, .. } => {
            let usage = format_progress(*used, *limit, format);
            (label.clone(), usage)
        }
        MetricLine::Text { label, value, .. } => {
            (label.clone(), value.clone())
        }
        MetricLine::Badge { label, text, .. } => {
            (label.clone(), text.clone())
        }
    }
}

fn format_progress(used: f64, limit: f64, fmt: &ProgressFormat) -> String {
    let ratio = (used / limit).clamp(0.0, 1.0);
    let filled = (ratio * BAR_WIDTH as f64).round() as usize;
    let empty = BAR_WIDTH - filled;

    let bar: String = std::iter::repeat(FULL_BLOCK)
        .take(filled)
        .chain(std::iter::repeat(LIGHT_SHADE).take(empty))
        .collect();

    let label = match fmt {
        ProgressFormat::Percent => format!("{}%", used as u64),
        ProgressFormat::Dollars => format!("${:.2} / ${:.2}", used, limit),
        ProgressFormat::Count { suffix } => format!("{}/{} {}", used as u64, limit as u64, suffix),
    };

    format!("{}  {}", bar, label)
}

fn render_table(rows: &[Row]) -> String {
    // Calculate column widths
    let w_provider = rows.iter().map(|r| r.provider.len()).max().unwrap_or(0).max(8);
    let w_plan = rows.iter().map(|r| r.plan.len()).max().unwrap_or(0).max(4);
    let w_metric = rows.iter().map(|r| r.metric.len()).max().unwrap_or(0).max(6);
    let w_usage = rows.iter().map(|r| r.usage.len()).max().unwrap_or(0).max(5);

    let mut out = String::new();

    // Header
    out.push_str(&format!(
        " {:<w_provider$}   {:<w_plan$}   {:<w_metric$}   {}\n",
        "Provider", "Plan", "Metric", "Usage",
    ));

    // Separator
    let total = w_provider + w_plan + w_metric + w_usage + 12;
    out.push_str(&"\u{2500}".repeat(total));
    out.push('\n');

    // Rows
    for row in rows {
        if row.separator_before {
            out.push_str(&"\u{00B7}".repeat(total));
            out.push('\n');
        }
        out.push_str(&format!(
            " {:<w_provider$}   {:<w_plan$}   {:<w_metric$}   {}\n",
            row.provider, row.plan, row.metric, row.usage,
        ));
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_progress_percent() {
        let result = format_progress(80.0, 100.0, &ProgressFormat::Percent);
        assert!(result.contains("80%"));
        // 80% of 10 = 8 filled blocks
        let filled: usize = result.chars().filter(|&c| c == FULL_BLOCK).count();
        assert_eq!(filled, 8);
        let empty: usize = result.chars().filter(|&c| c == LIGHT_SHADE).count();
        assert_eq!(empty, 2);
    }

    #[test]
    fn format_progress_dollars() {
        let result = format_progress(12.50, 50.0, &ProgressFormat::Dollars);
        assert!(result.contains("$12.50 / $50.00"));
    }

    #[test]
    fn format_progress_count() {
        let fmt = ProgressFormat::Count { suffix: "requests".to_string() };
        let result = format_progress(150.0, 500.0, &fmt);
        assert!(result.contains("150/500 requests"));
    }

    #[test]
    fn format_progress_zero() {
        let result = format_progress(0.0, 100.0, &ProgressFormat::Percent);
        let filled: usize = result.chars().filter(|&c| c == FULL_BLOCK).count();
        assert_eq!(filled, 0);
        let empty: usize = result.chars().filter(|&c| c == LIGHT_SHADE).count();
        assert_eq!(empty, 10);
    }

    #[test]
    fn format_progress_full() {
        let result = format_progress(100.0, 100.0, &ProgressFormat::Percent);
        let filled: usize = result.chars().filter(|&c| c == FULL_BLOCK).count();
        assert_eq!(filled, 10);
        let empty: usize = result.chars().filter(|&c| c == LIGHT_SHADE).count();
        assert_eq!(empty, 0);
    }

    #[test]
    fn format_progress_clamps_over_100() {
        let result = format_progress(150.0, 100.0, &ProgressFormat::Percent);
        let filled: usize = result.chars().filter(|&c| c == FULL_BLOCK).count();
        assert_eq!(filled, 10, "should clamp to full bar");
    }

    #[test]
    fn format_line_text() {
        let line = MetricLine::Text {
            label: "Today".to_string(),
            value: "1.5M tokens".to_string(),
            color: None,
            subtitle: None,
        };
        let (metric, usage) = format_line(&line);
        assert_eq!(metric, "Today");
        assert_eq!(usage, "1.5M tokens");
    }

    #[test]
    fn format_line_badge() {
        let line = MetricLine::Badge {
            label: "Status".to_string(),
            text: "Active".to_string(),
            color: None,
            subtitle: None,
        };
        let (metric, usage) = format_line(&line);
        assert_eq!(metric, "Status");
        assert_eq!(usage, "Active");
    }

    #[test]
    fn build_rows_groups_by_provider() {
        let outputs = vec![PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: Some("Max".to_string()),
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
            icon_url: String::new(),
        }];

        let rows = build_rows(&outputs);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].provider, "Claude");
        assert_eq!(rows[0].plan, "Max");
        assert_eq!(rows[1].provider, "", "second row should have empty provider");
        assert_eq!(rows[1].plan, "", "second row should have empty plan");
    }

    #[test]
    fn render_table_has_header_and_separator() {
        let rows = vec![Row {
            provider: "Claude".to_string(),
            plan: "Max".to_string(),
            metric: "Session".to_string(),
            usage: "80%".to_string(),
            separator_before: false,
        }];
        let output = render_table(&rows);
        assert!(output.contains("Provider"));
        assert!(output.contains("Plan"));
        assert!(output.contains("Metric"));
        assert!(output.contains("Usage"));
        assert!(output.contains("\u{2500}"), "should have horizontal line separator");
        assert!(output.contains("Claude"));
    }

    #[test]
    fn format_empty_outputs() {
        assert_eq!(format(&[], &HashMap::new()), "");
    }

    #[test]
    fn render_table_dotted_separator_between_providers() {
        let rows = vec![
            Row {
                provider: "Claude".to_string(),
                plan: "Max".to_string(),
                metric: "Session".to_string(),
                usage: "80%".to_string(),
                separator_before: false,
            },
            Row {
                provider: "Cursor".to_string(),
                plan: "Pro".to_string(),
                metric: "Fast".to_string(),
                usage: "40%".to_string(),
                separator_before: true,
            },
        ];
        let output = render_table(&rows);
        let lines: Vec<&str> = output.lines().collect();
        // Line 0: header, Line 1: solid separator, Line 2: Claude row, Line 3: dotted separator, Line 4: Cursor row
        assert!(lines[3].contains('\u{00B7}'), "should have dotted separator between providers");
    }

    #[test]
    fn format_empty_errors_no_logs_section() {
        let outputs = vec![PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: Some("Max".to_string()),
            lines: vec![MetricLine::Progress {
                label: "Session".to_string(),
                used: 80.0,
                limit: 100.0,
                format: ProgressFormat::Percent,
                resets_at: None,
                period_duration_ms: None,
                color: None,
            }],
            icon_url: String::new(),
        }];
        let result = format(&outputs, &HashMap::new());
        assert!(!result.contains("Logs"), "should not contain Logs section when errors is empty");
    }

    #[test]
    fn format_with_errors_shows_logs_section() {
        let mut errors = HashMap::new();
        errors.insert(
            "claude".to_string(),
            ProviderError {
                code: "provider_not_found".to_string(),
                message: "no plugin matches provider 'claude'".to_string(),
            },
        );
        errors.insert(
            "copilot".to_string(),
            ProviderError {
                code: "plugin_error".to_string(),
                message: "Not logged in. Run `gh auth login` first.".to_string(),
            },
        );
        let result = format(&[], &errors);
        assert!(result.contains("Logs\n"));
        assert!(result.contains("  [provider_not_found] claude: no plugin matches provider 'claude'\n"));
        assert!(result.contains("  [plugin_error] copilot: Not logged in. Run `gh auth login` first.\n"));
        // Check sorted order: claude before copilot
        let claude_pos = result.find("claude").unwrap();
        let copilot_pos = result.find("copilot").unwrap();
        assert!(claude_pos < copilot_pos, "errors should be sorted by provider ID");
    }

    #[test]
    fn format_multiple_providers() {
        let outputs = vec![
            PluginOutput {
                provider_id: "claude".to_string(),
                display_name: "Claude".to_string(),
                plan: Some("Max (5x)".to_string()),
                lines: vec![MetricLine::Progress {
                    label: "Session".to_string(),
                    used: 80.0,
                    limit: 100.0,
                    format: ProgressFormat::Percent,
                    resets_at: None,
                    period_duration_ms: None,
                    color: None,
                }],
                icon_url: String::new(),
            },
            PluginOutput {
                provider_id: "cursor".to_string(),
                display_name: "Cursor".to_string(),
                plan: Some("Pro".to_string()),
                lines: vec![MetricLine::Progress {
                    label: "Fast requests".to_string(),
                    used: 150.0,
                    limit: 500.0,
                    format: ProgressFormat::Count { suffix: "req".to_string() },
                    resets_at: None,
                    period_duration_ms: None,
                    color: None,
                }],
                icon_url: String::new(),
            },
        ];

        let output = format(&outputs, &HashMap::new());
        assert!(output.contains("Claude"));
        assert!(output.contains("Cursor"));
        assert!(output.contains("Session"));
        assert!(output.contains("Fast requests"));
    }
}
