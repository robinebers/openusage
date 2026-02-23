import { describe, expect, it, vi } from "vitest"

vi.mock("@tauri-apps/api/image", () => ({
  Image: {
    new: vi.fn(async () => ({})),
  },
}))

import { getTrayIconSizePx, makeTrayBarsSvg, renderTrayBarsIcon } from "@/lib/tray-bars-icon"

describe("tray-bars-icon", () => {
  it("getTrayIconSizePx renders 18px at 1x and 36px at 2x", () => {
    expect(getTrayIconSizePx(1)).toBe(18)
    expect(getTrayIconSizePx(2)).toBe(36)
  })

  it("renders provider icon", () => {
    const svg = makeTrayBarsSvg({
      sizePx: 36,
      providerIconUrl: "data:image/svg+xml;base64,ABC",
    })

    expect(svg).toContain("<image ")
    expect(svg).toContain('href="data:image/svg+xml;base64,ABC"')
    const viewBox = svg.match(/viewBox="0 0 (\d+) (\d+)"/)
    expect(viewBox).toBeTruthy()
    if (viewBox) {
      const width = Number(viewBox[1])
      const height = Number(viewBox[2])
      expect(width).toBe(height)
    }
  })

  it("falls back to circle glyph when provider icon is missing", () => {
    const svg = makeTrayBarsSvg({
      sizePx: 36,
    })
    expect(svg).not.toContain("<image ")
    expect(svg).toContain("<circle ")
  })

  it("never renders svg text", () => {
    const svg = makeTrayBarsSvg({
      sizePx: 18,
    })
    expect(svg).not.toContain("<text ")
  })

  it("renders svg text when percentage is provided", () => {
    const svg = makeTrayBarsSvg({
      sizePx: 18,
      percentText: "70%",
    })
    expect(svg).toContain(">70%</text>")
  })

  it("renderTrayBarsIcon rasterizes SVG to an Image using canvas", async () => {
    const originalImage = window.Image
    const originalCreateElement = document.createElement.bind(document)

    // Stub Image loader to immediately fire onload once src is set.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(window as any).Image = class MockImage {
      onload: null | (() => void) = null
      onerror: null | (() => void) = null
      decoding = "async"
      set src(_value: string) {
        queueMicrotask(() => this.onload?.())
      }
    }

    // Stub canvas context
    const ctx = {
      clearRect: () => {},
      drawImage: () => {},
      getImageData: (_x: number, _y: number, w: number, h: number) => ({
        data: new Uint8ClampedArray(w * h * 4),
      }),
    }

    // Patch createElement for canvas only
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(document as any).createElement = (tag: string) => {
      const el = originalCreateElement(tag)
      if (tag === "canvas") {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ;(el as any).getContext = () => ctx
      }
      return el
    }

    try {
      const img = await renderTrayBarsIcon({
        sizePx: 18,
      })
      expect(img).toBeTruthy()
    } finally {
      window.Image = originalImage
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(document as any).createElement = originalCreateElement
    }
  })
})
