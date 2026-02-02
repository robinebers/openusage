import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { SkeletonLine, SkeletonLines } from "@/components/skeleton-lines"
import type { ManifestLine } from "@/lib/plugin-types"

describe("SkeletonLines", () => {
  it("renders lines by type", () => {
    const lines: ManifestLine[] = [
      { type: "text", label: "Text" },
      { type: "badge", label: "Badge" },
      { type: "progress", label: "Progress" },
    ]
    render(<SkeletonLines lines={lines} />)
    expect(screen.getByText("Text")).toBeInTheDocument()
    expect(screen.getByText("Badge")).toBeInTheDocument()
    expect(screen.getByText("Progress")).toBeInTheDocument()
  })

  it("falls back on unknown type", () => {
    const line = { type: "nope", label: "Fallback" } as ManifestLine
    render(<SkeletonLine line={line} />)
    expect(screen.getByText("Fallback")).toBeInTheDocument()
  })
})
