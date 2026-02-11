import { trackEvent } from "@aptabase/tauri"

/**
 * Thin wrapper around Aptabase's trackEvent.
 * Aptabase only supports string and number property values.
 */
export function track(
  event: string,
  props?: Record<string, string | number>,
) {
  trackEvent(event, props)
}
