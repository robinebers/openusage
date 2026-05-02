export type RuntimePlatform = "windows" | "macos" | "other"

export function getRuntimePlatform(): RuntimePlatform {
  if (typeof navigator === "undefined") return "other"

  const nav = navigator as Navigator & {
    userAgentData?: { platform?: string }
  }
  const text = `${nav.userAgentData?.platform ?? navigator.platform ?? ""} ${navigator.userAgent ?? ""}`

  if (/win/i.test(text)) return "windows"
  if (/(mac|darwin)/i.test(text)) return "macos"
  return "other"
}

export function isWindowsRuntime(): boolean {
  return getRuntimePlatform() === "windows"
}
