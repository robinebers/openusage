import { invoke, isTauri } from "@tauri-apps/api/core"

/**
 * Thin wrapper around Aptabase's trackEvent.
 * Aptabase only supports string and number property values.
 */
const APTABASE_TRACK_EVENT_CMD = "plugin:aptabase|track_event"
const PROVIDER_FETCH_ERROR_TTL_MS = 60 * 60 * 1000
const providerFetchErrorLastSeenAt = new Map<string, number>()

function getProviderFetchErrorKey(
  props?: Record<string, string | number>,
): string | null {
  const providerId = props?.provider_id
  const error = props?.error
  if (providerId === undefined || error === undefined) return null
  return `${String(providerId)}::${String(error)}`
}

function shouldDropProviderFetchError(
  props?: Record<string, string | number>,
): boolean {
  const key = getProviderFetchErrorKey(props)
  if (!key) return false
  const now = Date.now()
  const lastSeenAt = providerFetchErrorLastSeenAt.get(key)
  if (lastSeenAt !== undefined && now - lastSeenAt < PROVIDER_FETCH_ERROR_TTL_MS) {
    return true
  }
  providerFetchErrorLastSeenAt.set(key, now)
  return false
}

export function track(
  event: string,
  props?: Record<string, string | number>,
) {
  const tauriRuntime = isTauri()

  if (!tauriRuntime) {
    return
  }

  if (event === "provider_fetch_error" && shouldDropProviderFetchError(props)) {
    return
  }

  void invoke(APTABASE_TRACK_EVENT_CMD, { name: event, props })
}
