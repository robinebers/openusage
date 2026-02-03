import { Image } from "@tauri-apps/api/image"

import type { TrayPrimaryBar } from "@/lib/tray-primary-progress"

function rgbaToImageDataBytes(rgba: Uint8ClampedArray): Uint8Array {
  // Image.new expects Uint8Array. Uint8ClampedArray shares the same buffer layout.
  return new Uint8Array(rgba.buffer)
}

export function makeTrayBarsSvg(args: {
  bars: TrayPrimaryBar[]
  sizePx: number
}): string {
  const { bars, sizePx } = args
  const n = Math.max(1, Math.min(4, bars.length || 1))

  const pad = Math.max(1, Math.round(sizePx * 0.08)) // ~2px at 24–36px
  const gap = Math.max(1, Math.round(sizePx * 0.03)) // ~1px at 36px
  const width = sizePx
  const height = sizePx

  const trackW = width - 2 * pad
  // For 1 bar, use same height as 2 bars (so it's not too chunky)
  const layoutN = Math.max(2, n)
  const trackH = Math.max(1, Math.floor((height - 2 * pad - (layoutN - 1) * gap) / layoutN))
  const rx = Math.max(1, Math.floor(trackH / 3))

  // Calculate vertical offset to center bars
  const totalBarsHeight = n * trackH + (n - 1) * gap
  const availableHeight = height - 2 * pad
  const yOffset = pad + Math.floor((availableHeight - totalBarsHeight) / 2)

  const trackOpacity = 0.22
  const fillOpacity = 1

  const parts: string[] = []
  parts.push(
    `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">`
  )

  for (let i = 0; i < n; i += 1) {
    const bar = bars[i]
    const y = yOffset + i * (trackH + gap)
    const x = pad

    // Track
    parts.push(
      `<rect x="${x}" y="${y}" width="${trackW}" height="${trackH}" rx="${rx}" fill="black" opacity="${trackOpacity}" />`
    )

    const fraction = bar?.fraction
    if (typeof fraction === "number" && Number.isFinite(fraction) && fraction >= 0) {
      const clamped = Math.max(0, Math.min(1, fraction))
      const fillW = Math.max(0, Math.round(trackW * clamped))
      if (fillW > 0) {
        parts.push(
          `<rect x="${x}" y="${y}" width="${fillW}" height="${trackH}" rx="${rx}" fill="black" opacity="${fillOpacity}" />`
        )
      }
    }
  }

  parts.push(`</svg>`)
  return parts.join("")
}

async function rasterizeSvgToRgba(svg: string, sizePx: number): Promise<Uint8Array> {
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
    canvas.width = sizePx
    canvas.height = sizePx

    const ctx = canvas.getContext("2d")
    if (!ctx) throw new Error("Canvas 2D context missing")

    // Clear to transparent; template icons use alpha as mask.
    ctx.clearRect(0, 0, sizePx, sizePx)
    ctx.drawImage(img, 0, 0, sizePx, sizePx)

    const imageData = ctx.getImageData(0, 0, sizePx, sizePx)
    return rgbaToImageDataBytes(imageData.data)
  } finally {
    URL.revokeObjectURL(url)
  }
}

export async function renderTrayBarsIcon(args: {
  bars: TrayPrimaryBar[]
  sizePx: number
}): Promise<Image> {
  const { bars, sizePx } = args
  const svg = makeTrayBarsSvg({ bars, sizePx })
  const rgba = await rasterizeSvgToRgba(svg, sizePx)
  return await Image.new(rgba, sizePx, sizePx)
}

export function getTrayIconSizePx(devicePixelRatio: number | undefined): number {
  const dpr = typeof devicePixelRatio === "number" && devicePixelRatio > 0 ? devicePixelRatio : 1
  // 18pt-ish slot -> render at 18px * dpr for crispness (36px on Retina).
  return Math.max(18, Math.round(18 * dpr))
}

