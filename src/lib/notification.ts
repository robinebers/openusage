export async function sendNotificationAsync(
  payload: Parameters<typeof import("@tauri-apps/plugin-notification").sendNotification>[0]
) {
  const { sendNotification } = await import("@tauri-apps/plugin-notification")
  return sendNotification(payload)
}
