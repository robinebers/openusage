mod ledger;
mod metering;
mod secrets;
mod server;
mod types;

pub use server::start_server;
use types::OpenAiProxySecretStatus;

#[cfg(test)]
use ledger::summarize_ledger;
#[cfg(test)]
use metering::{extract_usage_from_json, extract_usage_from_sse, price_usage};
#[cfg(test)]
use types::{LedgerEntry, ModelPrice, UsageTokens};

const SETTINGS_FILE_NAME: &str = "settings.json";
const SETTINGS_KEY: &str = "openaiCompatible";
const LEDGER_FILE_NAME: &str = "openai-compatible-usage.json";
const KEYCHAIN_UPSTREAM_SERVICE: &str = "OpenUsage OpenAI Compatible Upstream Key";
const KEYCHAIN_LOCAL_TOKEN_SERVICE: &str = "OpenUsage OpenAI Compatible Local Token";

#[tauri::command]
pub fn get_openai_proxy_secret_status() -> Result<OpenAiProxySecretStatus, String> {
    secrets::get_openai_proxy_secret_status()
}

#[tauri::command]
pub fn save_openai_proxy_upstream_key(value: String) -> Result<OpenAiProxySecretStatus, String> {
    secrets::save_openai_proxy_upstream_key(value)
}

#[tauri::command]
pub fn get_openai_proxy_local_token() -> Result<String, String> {
    secrets::get_openai_proxy_local_token()
}

#[tauri::command]
pub fn regenerate_openai_proxy_local_token() -> Result<String, String> {
    secrets::regenerate_openai_proxy_local_token()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prices_usage_by_exact_model_name() {
        let prices = vec![ModelPrice {
            model_name: "gpt-4.1-mini".to_string(),
            input_usd_per_1m: 0.40,
            output_usd_per_1m: 1.60,
        }];
        let usage = UsageTokens {
            input_tokens: 1_000_000,
            output_tokens: 500_000,
        };

        let priced = price_usage("gpt-4.1-mini", usage, &prices);

        assert_eq!(priced.input_tokens, 1_000_000);
        assert_eq!(priced.output_tokens, 500_000);
        assert_eq!(priced.cost_usd, Some(1.20));
        assert!(!priced.unpriced);
    }

    #[test]
    fn unpriced_model_records_tokens_without_cost() {
        let priced = price_usage(
            "new-model",
            UsageTokens {
                input_tokens: 123,
                output_tokens: 456,
            },
            &[],
        );

        assert_eq!(priced.cost_usd, None);
        assert!(priced.unpriced);
    }

    #[test]
    fn extracts_usage_from_chat_completion_json() {
        let body = r#"{
          "id": "chatcmpl-test",
          "usage": {
            "prompt_tokens": 11,
            "completion_tokens": 22,
            "total_tokens": 33
          }
        }"#;

        let usage = extract_usage_from_json(body).expect("usage");

        assert_eq!(usage.input_tokens, 11);
        assert_eq!(usage.output_tokens, 22);
    }

    #[test]
    fn extracts_usage_from_streaming_sse_when_present() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
            "data: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":9,\"total_tokens\":16}}\n\n",
            "data: [DONE]\n\n"
        );

        let usage = extract_usage_from_sse(body).expect("usage");

        assert_eq!(usage.input_tokens, 7);
        assert_eq!(usage.output_tokens, 9);
    }

    #[test]
    fn aggregates_ledger_for_today_month_and_total() {
        let entries = vec![
            LedgerEntry::metered("2026-06-05T01:00:00Z", "gpt-4.1-mini", 100, 200, Some(0.03)),
            LedgerEntry::metered("2026-06-04T01:00:00Z", "gpt-4.1-mini", 10, 20, Some(0.003)),
            LedgerEntry::unmetered("2026-05-31T01:00:00Z", "gpt-4.1-mini"),
        ];

        let summary = summarize_ledger(&entries, "2026-06-05T12:00:00Z");

        assert_eq!(summary.today.input_tokens, 100);
        assert_eq!(summary.today.output_tokens, 200);
        assert_eq!(summary.today.cost_usd, 0.03);
        assert_eq!(summary.month.input_tokens, 110);
        assert_eq!(summary.month.output_tokens, 220);
        assert_eq!(summary.total.unmetered_requests, 1);
    }
}
