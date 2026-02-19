import { invoke, isTauri } from "@tauri-apps/api/core"

/**
 * Thin wrapper around Aptabase's trackEvent.
 * Aptabase only supports string and number property values.
 */
const APTABASE_TRACK_EVENT_CMD = "plugin:aptabase|track_event"

export function track(
  event: string,
  props?: Record<string, string | number>,
) {
  const tauriRuntime = isTauri()

  if (!tauriRuntime) {
    return
  }

  void invoke(APTABASE_TRACK_EVENT_CMD, { name: event, props })
}
