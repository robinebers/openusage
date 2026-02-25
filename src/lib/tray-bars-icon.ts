import { Image } from "@tauri-apps/api/image"
import type { MenubarIconStyle } from "@/lib/settings"
import type { TrayPrimaryBar } from "@/lib/tray-primary-progress"

const PROVIDER_ICON_SHRINK_PX = 1
const PROVIDER_ICON_VERTICAL_NUDGE_PX = 0
const BARS_TRACK_OPACITY = 0.16
const BARS_REMAINDER_OPACITY = 0.24
const BARS_FILL_OPACITY = 1

function rgbaToImageDataBytes(rgba: Uint8ClampedArray): Uint8Array {
  // Image.new expects Uint8Array. Uint8ClampedArray shares the same buffer layout.
  return new Uint8Array(rgba.buffer)
}

function escapeXmlText(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;")
}

function makeRoundedBarPath(args: {
  x: number
  y: number
  w: number
  h: number
  leftRadius: number
  rightRadius: number
}): string {
  const { x, y, w, h } = args
  const leftRadius = Math.max(0, Math.min(args.leftRadius, h / 2, w / 2))
  const rightRadius = Math.max(0, Math.min(args.rightRadius, h / 2, w / 2))
  const x1 = x + w
  const y1 = y + h
  return [
    `M ${x + leftRadius} ${y}`,
    `L ${x1 - rightRadius} ${y}`,
    `A ${rightRadius} ${rightRadius} 0 0 1 ${x1} ${y + rightRadius}`,
    `L ${x1} ${y1 - rightRadius}`,
    `A ${rightRadius} ${rightRadius} 0 0 1 ${x1 - rightRadius} ${y1}`,
    `L ${x + leftRadius} ${y1}`,
    `A ${leftRadius} ${leftRadius} 0 0 1 ${x} ${y1 - leftRadius}`,
    `L ${x} ${y + leftRadius}`,
    `A ${leftRadius} ${leftRadius} 0 0 1 ${x + leftRadius} ${y}`,
    "Z",
  ].join(" ")
}

function getMinVisibleRemainderPx(trackW: number): number {
  // Keep remainder clearly visible after tray downsampling.
  return Math.max(4, Math.round(trackW * 0.2))
}

function getVisualBarFraction(fraction: number): number {
  if (!Number.isFinite(fraction)) return 0
  const clamped = Math.max(0, Math.min(1, fraction))
  if (clamped > 0.7 && clamped < 1) {
    // Quantize high-end bars by remainder in 15% steps so near-full values
    // still leave a meaningful visible tail.
    const remainder = 1 - clamped
    const quantizedRemainder = Math.min(1, Math.ceil(remainder / 0.15) * 0.15)
    return Math.max(0, 1 - quantizedRemainder)
  }
  return clamped
}

export function getBarFillLayout(trackW: number, fraction: number): {
  fillW: number
  remainderDrawW: number
  dividerX: number | null
} {
  if (!Number.isFinite(fraction) || fraction <= 0) {
    return { fillW: 0, remainderDrawW: 0, dividerX: null }
  }

  const visual = getVisualBarFraction(fraction)
  if (visual >= 1) {
    return { fillW: trackW, remainderDrawW: 0, dividerX: null }
  }

  const minVisibleRemainderPx = getMinVisibleRemainderPx(trackW)
  const maxFillW = Math.max(1, trackW - minVisibleRemainderPx)
  const fillW = Math.max(1, Math.min(maxFillW, Math.round(trackW * visual)))
  const trueRemainderW = trackW - fillW
  const remainderDrawW = Math.min(trackW - 1, Math.max(trueRemainderW, minVisibleRemainderPx))
  const dividerX = trackW - remainderDrawW
  return { fillW, remainderDrawW, dividerX }
}

function normalizePercentText(percentText: string | undefined): string | undefined {
  if (typeof percentText !== "string") return undefined
  const trimmed = percentText.trim()
  return trimmed.length > 0 ? trimmed : undefined
}

function estimateTextWidthPx(text: string, fontSize: number): number {
  // Empirical estimate for SF Pro bold numeric glyphs in tray-sized icons.
  return Math.ceil(text.length * fontSize * 0.62 + fontSize * 0.2)
}

function getSvgLayout(args: {
  sizePx: number
  style: MenubarIconStyle
  percentText?: string
}): {
  width: number
  height: number
  pad: number
  gap: number
  barsX: number
  barsWidth: number
  textX: number
  textY: number
  fontSize: number
} {
  const { sizePx, style, percentText } = args
  const hasPercentText = typeof percentText === "string" && percentText.length > 0
  const verticalNudgePx = 1
  const pad = Math.max(1, Math.round(sizePx * 0.08)) // ~2px at 24–36px
  const gap = Math.max(1, Math.round(sizePx * 0.03)) // ~1px at 36px

  const height = sizePx
  const barsX = pad
  const barsWidth = sizePx - 2 * pad
  const fontSize = Math.max(9, Math.round(sizePx * 0.72))
  const textWidth = hasPercentText ? estimateTextWidthPx(percentText, fontSize) : 0
  // Optical correction + global nudge down to align with the tray slot center.
  const textY = Math.round(sizePx / 2) + 1 + verticalNudgePx

  if (style === "donut") {
    const donutGap = Math.max(1, Math.round(sizePx * 0.06))
    return {
      width: sizePx + donutGap + sizePx,
      height,
      pad,
      gap,
      barsX,
      barsWidth,
      textX: 0,
      textY,
      fontSize,
    }
  }

  if (!hasPercentText) {
    return {
      width: sizePx,
      height,
      pad,
      gap,
      barsX,
      barsWidth,
      textX: 0,
      textY,
      fontSize,
    }
  }

  const textGap = Math.max(2, Math.round(sizePx * 0.08))
  const textAreaWidth = Math.max(20, Math.round(sizePx * 1.5), textWidth + pad)
  const rightPad = pad

  return {
    width: sizePx + textGap + textAreaWidth + rightPad,
    height,
    pad,
    gap,
    barsX,
    barsWidth,
    textX: sizePx + textGap,
    textY,
    fontSize,
  }
}

export function makeTrayBarsSvg(args: {
  bars: TrayPrimaryBar[]
  sizePx: number
  style?: MenubarIconStyle
  percentText?: string
  providerIconUrl?: string
}): string {
  const { bars, sizePx, style = "provider", percentText, providerIconUrl } = args
  const barsForStyle = style === "bars" ? bars : bars.slice(0, 1)
  // Intentionally render a single empty track when bars mode has no data yet
  // so the tray icon keeps a stable shape during loading/initialization.
  const n = Math.max(1, Math.min(4, barsForStyle.length || 1))
  const text = normalizePercentText(percentText)
  const layout = getSvgLayout({
    sizePx,
    style,
    percentText: text,
  })

  const width = layout.width
  const height = layout.height
  const trackW = layout.barsWidth

  const parts: string[] = []
  parts.push(
    `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">`
  )

  if (style === "provider") {
    const hasText = typeof text === "string" && text.length > 0
    const iconSize = Math.max(6, Math.round(sizePx - 2 * layout.pad * 0.5) - (hasText ? PROVIDER_ICON_SHRINK_PX : 0))
    const x = layout.barsX
    const y = Math.round((height - iconSize) / 2) + (hasText ? PROVIDER_ICON_VERTICAL_NUDGE_PX : 0)
    const href = typeof providerIconUrl === "string" ? providerIconUrl.trim() : ""

    if (href.length > 0) {
      parts.push(
        `<image x="${x}" y="${y}" width="${iconSize}" height="${iconSize}" href="${escapeXmlText(href)}" preserveAspectRatio="xMidYMid meet" />`
      )
    } else {
      const cx = x + iconSize / 2
      const cy = y + iconSize / 2
      const radius = Math.max(2, iconSize / 2 - 1.5)
      const strokeW = Math.max(1.5, Math.round(iconSize * 0.14))
      parts.push(
        `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="none" stroke="black" stroke-width="${strokeW}" opacity="1" shape-rendering="geometricPrecision" />`
      )
    }
  } else if (style === "donut") {
    const iconSize = Math.max(6, Math.round(sizePx - 2 * layout.pad * 0.5))
    const iconX = layout.barsX
    const iconY = Math.round((height - iconSize) / 2)
    const href = typeof providerIconUrl === "string" ? providerIconUrl.trim() : ""

    if (href.length > 0) {
      parts.push(
        `<image x="${iconX}" y="${iconY}" width="${iconSize}" height="${iconSize}" href="${escapeXmlText(href)}" preserveAspectRatio="xMidYMid meet" />`
      )
    } else {
      const fcx = iconX + iconSize / 2
      const fcy = iconY + iconSize / 2
      const fallbackR = Math.max(2, iconSize / 2 - 1.5)
      const fallbackSW = Math.max(1.5, Math.round(iconSize * 0.14))
      parts.push(
        `<circle cx="${fcx}" cy="${fcy}" r="${fallbackR}" fill="none" stroke="black" stroke-width="${fallbackSW}" opacity="1" shape-rendering="geometricPrecision" />`
      )
    }

    const donutGap = Math.max(1, Math.round(sizePx * 0.06))
    const donutAreaX = sizePx + donutGap
    const chartSize = Math.max(6, sizePx - 2 * layout.pad)
    const cx = donutAreaX + layout.pad + chartSize / 2
    const cy = height / 2 + 1
    const strokeW = Math.max(2, Math.round(chartSize * 0.16))
    const radius = Math.max(1, Math.floor(chartSize / 2 - strokeW / 2) + 0.5)

    parts.push(
      `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="none" stroke="black" stroke-width="${strokeW}" opacity="${BARS_TRACK_OPACITY}" shape-rendering="geometricPrecision" />`
    )

    const fraction = barsForStyle[0]?.fraction
    if (typeof fraction === "number" && Number.isFinite(fraction) && fraction >= 0) {
      const clamped = Math.max(0, Math.min(1, fraction))
      if (clamped > 0) {
        const circumference = 2 * Math.PI * radius
        const dash = circumference * clamped
        parts.push(
          `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="none" stroke="black" stroke-width="${strokeW}" stroke-linecap="butt" stroke-dasharray="${dash} ${circumference}" transform="rotate(-90 ${cx} ${cy})" opacity="${BARS_FILL_OPACITY}" shape-rendering="geometricPrecision" />`
        )
      }
    }
  } else {
    // style === "bars"
    const trackOpacity = BARS_TRACK_OPACITY
    const remainderOpacity = BARS_REMAINDER_OPACITY
    const fillOpacity = BARS_FILL_OPACITY

    const layoutN = Math.max(2, n)
    const trackH = Math.max(
      1,
      Math.floor((height - 2 * layout.pad - (layoutN - 1) * layout.gap) / layoutN)
    )
    const rx = Math.max(1, Math.floor(trackH / 3))

    const totalBarsHeight = n * trackH + (n - 1) * layout.gap
    const availableHeight = height - 2 * layout.pad
    const yOffset = layout.pad + Math.floor((availableHeight - totalBarsHeight) / 2)

    for (let i = 0; i < n; i += 1) {
      const bar = barsForStyle[i]
      const y = yOffset + i * (trackH + layout.gap) + 1
      const x = layout.barsX

      parts.push(
        `<rect x="${x}" y="${y}" width="${trackW}" height="${trackH}" rx="${rx}" fill="black" opacity="${trackOpacity}" />`
      )

      const fraction = bar?.fraction
      if (typeof fraction === "number" && Number.isFinite(fraction) && fraction >= 0) {
        const { fillW, remainderDrawW, dividerX } = getBarFillLayout(trackW, fraction)
        if (fillW > 0) {
          const movingEdgeRadius = Math.max(0, Math.floor(rx * 0.35))
          if (fillW >= trackW) {
            parts.push(
              `<rect x="${x}" y="${y}" width="${fillW}" height="${trackH}" rx="${rx}" fill="black" opacity="${fillOpacity}" />`
            )
          } else {
            const fillPath = makeRoundedBarPath({
              x,
              y,
              w: fillW,
              h: trackH,
              leftRadius: rx,
              rightRadius: movingEdgeRadius,
            })
            parts.push(`<path d="${fillPath}" fill="black" opacity="${fillOpacity}" />`)
          }
        }

        if (fillW > 0 && remainderDrawW > 0 && dividerX !== null) {
          const remainderX = x + dividerX
          const remainderPath = makeRoundedBarPath({
            x: remainderX,
            y,
            w: remainderDrawW,
            h: trackH,
            leftRadius: Math.max(0, Math.floor(rx * 0.2)),
            rightRadius: rx,
          })
          parts.push(`<path d="${remainderPath}" fill="black" opacity="${remainderOpacity}" />`)
        }
      }
    }
  }

  if (text) {
    parts.push(
      `<text x="${layout.textX}" y="${layout.textY}" fill="black" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="${layout.fontSize}" font-weight="700" dominant-baseline="middle">${escapeXmlText(text)}</text>`
    )
  }

  parts.push(`</svg>`)
  return parts.join("")
}

async function rasterizeSvgToRgba(svg: string, widthPx: number, heightPx: number): Promise<Uint8Array> {
  const blob = new Blob([svg], { type: "image/svg+xml" })
  const url = URL.createObjectURL(blob)
  try {
    const img = new window.Image()
    img.decoding = "async"

    const loaded = new Promise<void>((resolve, reject) => {
      img.onload = () => resolve()
      img.onerror = () => reject(new Error("Failed to load SVG into image"))
    })

    img.src = url
    await loaded

    const canvas = document.createElement("canvas")
    canvas.width = widthPx
    canvas.height = heightPx

    const ctx = canvas.getContext("2d")
    if (!ctx) throw new Error("Canvas 2D context missing")

    // Clear to transparent; template icons use alpha as mask.
    ctx.clearRect(0, 0, widthPx, heightPx)
    ctx.drawImage(img, 0, 0, widthPx, heightPx)

    const imageData = ctx.getImageData(0, 0, widthPx, heightPx)
    return rgbaToImageDataBytes(imageData.data)
  } finally {
    URL.revokeObjectURL(url)
  }
}

export async function renderTrayBarsIcon(args: {
  bars: TrayPrimaryBar[]
  sizePx: number
  style?: MenubarIconStyle
  percentText?: string
  providerIconUrl?: string
}): Promise<Image> {
  const { bars, sizePx, style = "provider", percentText, providerIconUrl } = args
  const text = normalizePercentText(percentText)
  const svg = makeTrayBarsSvg({
    bars,
    sizePx,
    style,
    percentText: text,
    providerIconUrl,
  })
  const layout = getSvgLayout({
    sizePx,
    style,
    percentText: text,
  })
  const rgba = await rasterizeSvgToRgba(svg, layout.width, layout.height)
  return await Image.new(rgba, layout.width, layout.height)
}

export function getTrayIconSizePx(devicePixelRatio: number | undefined): number {
  const dpr = typeof devicePixelRatio === "number" && devicePixelRatio > 0 ? devicePixelRatio : 1
  // 18pt-ish slot -> render at 18px * dpr for crispness (36px on Retina).
  return Math.max(18, Math.round(18 * dpr))
}
