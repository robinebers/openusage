use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelPrice {
    pub model_name: String,
    pub input_usd_per_1m: f64,
    pub output_usd_per_1m: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsageTokens {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PricedUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: Option<f64>,
    pub unpriced: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAiCompatibleSettings {
    pub enabled: bool,
    pub endpoint: String,
    pub prices: Vec<ModelPrice>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAiProxySecretStatus {
    pub has_upstream_key: bool,
    pub has_local_token: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerEntry {
    pub fetched_at: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: Option<f64>,
    pub unpriced: bool,
    pub unmetered: bool,
}

impl LedgerEntry {
    #[cfg(test)]
    pub fn metered(
        fetched_at: &str,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: Option<f64>,
    ) -> Self {
        Self {
            fetched_at: fetched_at.to_string(),
            model: model.to_string(),
            input_tokens,
            output_tokens,
            cost_usd,
            unpriced: cost_usd.is_none(),
            unmetered: false,
        }
    }

    pub fn unmetered(fetched_at: &str, model: &str) -> Self {
        Self {
            fetched_at: fetched_at.to_string(),
            model: model.to_string(),
            input_tokens: 0,
            output_tokens: 0,
            cost_usd: None,
            unpriced: false,
            unmetered: true,
        }
    }
}
