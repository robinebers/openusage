use super::types::{ModelPrice, PricedUsage, UsageTokens};
use serde_json::Value;

pub fn price_usage(model: &str, usage: UsageTokens, prices: &[ModelPrice]) -> PricedUsage {
    let price = prices.iter().find(|price| price.model_name == model);
    let cost_usd = price.map(|price| {
        let raw = (usage.input_tokens as f64 / 1_000_000.0) * price.input_usd_per_1m
            + (usage.output_tokens as f64 / 1_000_000.0) * price.output_usd_per_1m;
        (raw * 1_000_000_000_000.0).round() / 1_000_000_000_000.0
    });

    PricedUsage {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost_usd,
        unpriced: cost_usd.is_none(),
    }
}

pub fn extract_usage_from_json(body: &str) -> Option<UsageTokens> {
    let value: Value = serde_json::from_str(body).ok()?;
    usage_from_value(value.get("usage")?)
}

pub fn extract_usage_from_sse(body: &str) -> Option<UsageTokens> {
    let mut found = None;
    for line in body.lines() {
        let Some(data) = line.trim().strip_prefix("data:") else {
            continue;
        };
        let data = data.trim();
        if data.is_empty() || data == "[DONE]" {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(data) else {
            continue;
        };
        if let Some(usage) = value.get("usage").and_then(usage_from_value) {
            found = Some(usage);
        }
    }
    found
}

fn usage_from_value(usage: &Value) -> Option<UsageTokens> {
    let input = usage
        .get("input_tokens")
        .or_else(|| usage.get("prompt_tokens"))?
        .as_u64()?;
    let output = usage
        .get("output_tokens")
        .or_else(|| usage.get("completion_tokens"))?
        .as_u64()?;
    Some(UsageTokens {
        input_tokens: input,
        output_tokens: output,
    })
}
