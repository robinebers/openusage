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

export type TrayGridCell = {
  text: string
}

function estimateTextWidthPx(text: string, fontSize: number): number {
  return Math.ceil(text.length * fontSize * 0.60 + fontSize * 0.2)
}

function getSvgLayout(args: {
  sizePx: number
  gridCells: TrayGridCell[]
  hideIcon?: boolean
}): {
  width: number
  height: number
  pad: number
  barsX: number
  iconSize: number
  texts: { x: number; y: number; text: string; fontSize: number }[]
} {
  const { sizePx, gridCells, hideIcon = false } = args
  const pad = Math.max(1, Math.round(sizePx * 0.08)) // ~2px at 24–36px

  const height = sizePx
  const barsX = pad
  const iconSize = Math.max(6, Math.round(sizePx - 2 * pad * 0.5))

  if (gridCells.length === 0) {
    return {
      // Keep a non-zero canvas to avoid invalid raster/image dimensions.
      width: sizePx,
      height,
      pad,
      barsX,
      iconSize,
      texts: [],
    }
  }

  const visibleCells = gridCells.slice(0, 4)

  // Define layout configuration
  // 1 item -> 1 col, 1 row (center)
  // 2 items -> 1 col, 2 rows (stack)
  // 3 items -> 2 cols, (col 1: 2 rows, col 2: top row)
  // 4 items -> 2 cols, 2 rows per col
  const numItems = visibleCells.length
  const useTwoCols = numItems > 2
  const numRows = numItems > 1 ? 2 : 1

  // Compute base fonts based on row count
  const fontSize = numRows === 1 ? Math.max(9, Math.round(sizePx * 0.68)) : Math.max(8, Math.round(sizePx * 0.55))
  const textGap = Math.max(2, Math.round(sizePx * 0.08))
  const startX = hideIcon ? pad : sizePx + textGap

  // Measure columns and place texts
  const texts: { x: number; y: number; text: string; fontSize: number }[] = []

  let col1Width = 0
  let col2Width = 0

  // Pass 1: measure max widths
  for (let i = 0; i < visibleCells.length; i++) {
    const w = estimateTextWidthPx(visibleCells[i].text, fontSize)
    if (useTwoCols && i >= 2) {
      col2Width = Math.max(col2Width, w)
    } else {
      col1Width = Math.max(col1Width, w)
    }
  }

  // Pass 2: Layout
  // Column Gap, visual separator |
  const colGapPx = useTwoCols ? Math.max(6, Math.round(sizePx * 0.3)) : 0

  for (let i = 0; i < visibleCells.length; i++) {
    const isCol2 = useTwoCols && i >= 2
    const isRow2 = i % 2 === 1

    // X position
    let textX = startX
    if (isCol2) {
      textX = startX + col1Width + colGapPx
    }

    // Y position
    let textY = Math.round(sizePx / 2) + 1
    if (numRows === 2) {
      if (!isRow2) {
        textY = Math.round(sizePx * 0.26) + 1
      } else {
        textY = Math.round(sizePx * 0.78) + 1
      }
    }

    texts.push({
      x: textX,
      y: textY,
      text: visibleCells[i].text,
      fontSize
    })
  }

  // Include separator line text logic if using two cols
  if (useTwoCols) {
    texts.push({
      x: startX + col1Width + Math.floor(colGapPx / 2),
      y: Math.round(sizePx / 2) + 1,
      text: "|",
      fontSize: Math.max(10, Math.round(sizePx * 0.7))
    })
  }

  const totalTextWidth = col1Width + (useTwoCols ? colGapPx + col2Width : 0)

  return {
    width: Math.round(startX + totalTextWidth + pad),
    height,
    pad,
    barsX,
    iconSize,
    texts,
  }
}

export function makeTrayBarsSvg(args: {
  sizePx: number
  gridCells?: TrayGridCell[]
  providerIconUrl?: string
  hideIcon?: boolean
}): string {
  const { sizePx, providerIconUrl, gridCells = [], hideIcon = false } = args

  const layout = getSvgLayout({
    sizePx,
    gridCells,
    hideIcon,
  })

  const width = layout.width
  const height = layout.height

  const parts: string[] = []
  parts.push(
    `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">`
  )

  const x = layout.barsX
  const y = Math.round((height - layout.iconSize) / 2) + 1
  const href = typeof providerIconUrl === "string" ? providerIconUrl.trim() : ""

  if (!hideIcon) {
    if (href.length > 0) {
      parts.push(
        `<image x="${x}" y="${y}" width="${layout.iconSize}" height="${layout.iconSize}" href="${escapeXmlText(href)}" preserveAspectRatio="xMidYMid meet" />`
      )
    } else {
      const cx = x + layout.iconSize / 2
      const cy = y + layout.iconSize / 2
      const radius = Math.max(2, layout.iconSize / 2 - 1.5)
      const strokeW = Math.max(1.5, Math.round(layout.iconSize * 0.14))
      parts.push(
        `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="none" stroke="black" stroke-width="${strokeW}" opacity="1" shape-rendering="geometricPrecision" />`
      )
    }
  }

  // Align horizontal centers, baseline middle
  for (const { x: tX, y: tY, text, fontSize } of layout.texts) {
    const anchor = text === "|" ? "middle" : "start"
    const opacity = text === "|" ? "0.3" : "1"
    parts.push(
      `<text x="${tX}" y="${tY}" fill="black" opacity="${opacity}" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="${fontSize}" font-weight="700" text-anchor="${anchor}" dominant-baseline="middle">${escapeXmlText(text)}</text>`
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
  gridCells?: TrayGridCell[]
  providerIconUrl?: string
  hideIcon?: boolean
}): Promise<Image> {
  const { sizePx, gridCells, providerIconUrl, hideIcon = false } = args
  const svg = makeTrayBarsSvg({
    sizePx,
    gridCells,
    providerIconUrl,
    hideIcon,
  })
  const layout = getSvgLayout({
    sizePx,
    gridCells: gridCells || [],
    hideIcon,
  })
  const rgba = await rasterizeSvgToRgba(svg, layout.width, layout.height)
  return await Image.new(rgba, layout.width, layout.height)
}

export function getTrayIconSizePx(devicePixelRatio: number | undefined): number {
  const dpr = typeof devicePixelRatio === "number" && devicePixelRatio > 0 ? devicePixelRatio : 1
  // 18pt-ish slot -> render at 18px * dpr for crispness (36px on Retina).
  return Math.max(18, Math.round(18 * dpr))
}
