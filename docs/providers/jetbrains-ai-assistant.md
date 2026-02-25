# JetBrains AI Assistant

Tracks JetBrains AI Assistant quota from the local IDE quota cache.

## Data Source

The plugin reads `AIAssistantQuotaManager2.xml` from JetBrains IDE config directories.

### Candidate base directories

- macOS: `~/Library/Application Support/JetBrains`
- Linux: `~/.config/JetBrains`
- Windows: `~/AppData/Roaming/JetBrains`

For each base directory, the plugin lists real IDE directories on disk (WebStorm, IntelliJ IDEA, PyCharm, etc.), then picks the valid entry with the latest quota window.

## Parsed Fields

From `quotaInfo`:
- `current` -> used quota
- `maximum` -> quota limit
- `available` -> remaining quota
- `until` -> next reset timestamp

From `nextRefill`:
- `tariff.duration` -> period duration when present (for pacing in UI)
- `next` -> primary renewal/reset timestamp used in OpenUsage

From nested quota buckets:
- `tariffQuota.available` + `topUpQuota.available` are used as remaining when top-level `available` is missing.
- Large raw values are normalized to credits for display (JetBrains stores quota in finer-grained internal units).

## Displayed Lines

| Line      | Scope    | Description |
|-----------|----------|-------------|
| Quota     | Overview | Used percentage |
| Used      | Detail   | Used quota amount |
| Remaining | Detail   | Remaining quota |

## Errors

| Condition | Message |
|-----------|---------|
| No valid quota file found | "JetBrains AI Assistant not detected. Open a JetBrains IDE with AI Assistant enabled." |
| Quota file present but invalid | "JetBrains AI Assistant quota data unavailable. Open AI Assistant once and try again." |
