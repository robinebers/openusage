use super::types::LedgerEntry;
use super::LEDGER_FILE_NAME;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{Mutex, OnceLock};

#[cfg(test)]
use std::collections::{BTreeMap, HashSet};

#[cfg(test)]
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageBucket {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: f64,
    pub unmetered_requests: u64,
}

#[cfg(test)]
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LedgerSummary {
    pub today: UsageBucket,
    pub month: UsageBucket,
    pub total: UsageBucket,
    pub unpriced_models: Vec<String>,
    pub daily_costs: Vec<DailyCost>,
}

#[cfg(test)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DailyCost {
    pub date: String,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LedgerFile {
    version: u32,
    entries: Vec<LedgerEntry>,
}

#[cfg(test)]
pub fn summarize_ledger(entries: &[LedgerEntry], now_iso: &str) -> LedgerSummary {
    let today_prefix = now_iso.get(0..10).unwrap_or_default();
    let month_prefix = now_iso.get(0..7).unwrap_or_default();
    let mut summary = LedgerSummary::default();
    let mut unpriced = HashSet::new();
    let mut daily = BTreeMap::<String, f64>::new();

    for entry in entries {
        add_to_bucket(&mut summary.total, entry);
        if entry.fetched_at.starts_with(today_prefix) {
            add_to_bucket(&mut summary.today, entry);
        }
        if entry.fetched_at.starts_with(month_prefix) {
            add_to_bucket(&mut summary.month, entry);
        }
        if entry.unpriced {
            unpriced.insert(entry.model.clone());
        }
        if let (Some(day), Some(cost)) = (entry.fetched_at.get(0..10), entry.cost_usd) {
            *daily.entry(day.to_string()).or_insert(0.0) += cost;
        }
    }

    summary.unpriced_models = unpriced.into_iter().collect();
    summary.unpriced_models.sort();
    summary.daily_costs = daily
        .into_iter()
        .map(|(date, cost_usd)| DailyCost { date, cost_usd })
        .collect();
    summary
}

#[cfg(test)]
fn add_to_bucket(bucket: &mut UsageBucket, entry: &LedgerEntry) {
    bucket.input_tokens = bucket.input_tokens.saturating_add(entry.input_tokens);
    bucket.output_tokens = bucket.output_tokens.saturating_add(entry.output_tokens);
    bucket.cost_usd += entry.cost_usd.unwrap_or(0.0);
    if entry.unmetered {
        bucket.unmetered_requests = bucket.unmetered_requests.saturating_add(1);
    }
}

pub fn load_ledger(app_data_dir: &Path) -> Vec<LedgerEntry> {
    let path = app_data_dir.join(LEDGER_FILE_NAME);
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    match serde_json::from_str::<LedgerFile>(&text) {
        Ok(file) if file.version == 1 => file.entries,
        _ => Vec::new(),
    }
}

fn save_ledger(app_data_dir: &Path, entries: &[LedgerEntry]) -> Result<(), String> {
    let file = LedgerFile {
        version: 1,
        entries: entries.to_vec(),
    };
    let json = serde_json::to_string(&file).map_err(|e| e.to_string())?;
    std::fs::write(app_data_dir.join(LEDGER_FILE_NAME), json).map_err(|e| e.to_string())
}

fn ledger_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

pub fn append_ledger_entry(app_data_dir: &Path, entry: LedgerEntry) {
    let _guard = ledger_lock().lock().expect("openai proxy ledger lock poisoned");
    let mut entries = load_ledger(app_data_dir);
    entries.push(entry);
    if let Err(error) = save_ledger(app_data_dir, &entries) {
        log::warn!("failed to save OpenAI-compatible usage ledger: {}", error);
    }
}
