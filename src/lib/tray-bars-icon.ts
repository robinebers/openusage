import { Image } from "@tauri-apps/api/image"

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

function getSvgLayout(args: {
  sizePx: number
}): {
  width: number
  height: number
  pad: number
  barsX: number
} {
  const { sizePx } = args
  const pad = Math.max(1, Math.round(sizePx * 0.08)) // ~2px at 24–36px

  const height = sizePx
  const barsX = pad
  return {
    width: sizePx,
    height,
    pad,
    barsX,
  }
}

export function makeTrayBarsSvg(args: {
  sizePx: number
  providerIconUrl?: string
}): string {
  const { sizePx, providerIconUrl } = args
  const layout = getSvgLayout({
    sizePx,
  })

  const width = layout.width
  const height = layout.height

  const parts: string[] = []
  parts.push(
    `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">`
  )

  const iconSize = Math.max(6, Math.round(sizePx - 2 * layout.pad * 0.5))
  const x = layout.barsX
  const y = Math.round((height - iconSize) / 2) + 1
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
  sizePx: number
  providerIconUrl?: string
}): Promise<Image> {
  const { sizePx, providerIconUrl } = args
  const svg = makeTrayBarsSvg({
    sizePx,
    providerIconUrl,
  })
  const layout = getSvgLayout({
    sizePx,
  })
  const rgba = await rasterizeSvgToRgba(svg, layout.width, layout.height)
  return await Image.new(rgba, layout.width, layout.height)
}

export function getTrayIconSizePx(devicePixelRatio: number | undefined): number {
  const dpr = typeof devicePixelRatio === "number" && devicePixelRatio > 0 ? devicePixelRatio : 1
  // 18pt-ish slot -> render at 18px * dpr for crispness (36px on Retina).
  return Math.max(18, Math.round(18 * dpr))
}
