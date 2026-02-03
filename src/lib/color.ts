function sRGBtoLinear(c: number) {
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
}

export function getRelativeLuminance(hex: string): number {
  let h = hex.startsWith("#") ? hex.slice(1) : hex
  if (h.length === 3 || h.length === 4) {
    h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  } else if (h.length === 8) {
    h = h.slice(0, 6)
  }
  if (h.length !== 6 || !/^[0-9a-fA-F]{6}$/.test(h)) return 0
  const r = parseInt(h.slice(0, 2), 16) / 255
  const g = parseInt(h.slice(2, 4), 16) / 255
  const b = parseInt(h.slice(4, 6), 16) / 255
  return 0.2126 * sRGBtoLinear(r) + 0.7152 * sRGBtoLinear(g) + 0.0722 * sRGBtoLinear(b)
}

export type BadgeStyle = { background: string; color: string }

export function getBadgeStyle(brandColor: string | undefined, isDark: boolean): BadgeStyle | undefined {
  if (!brandColor) return undefined
  const luminance = getRelativeLuminance(brandColor)
  // Skip colors with poor contrast against the theme background
  if (isDark && luminance < 0.15) return undefined
  if (!isDark && luminance > 0.85) return undefined
  // Use white text on dark backgrounds, dark text on light backgrounds
  const textColor = luminance > 0.5 ? "#1a1a1a" : "#ffffff"
  return { background: brandColor, color: textColor }
}
