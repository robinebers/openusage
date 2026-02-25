import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { SkeletonLine, SkeletonLines } from "@/components/skeleton-lines"
import type { ManifestLine } from "@/lib/plugin-types"

describe("SkeletonLines", () => {
  it("renders lines by type", () => {
    const lines: ManifestLine[] = [
      { type: "text", label: "Text", scope: "overview" },
      { type: "badge", label: "Badge", scope: "overview" },
      { type: "progress", label: "Progress", scope: "detail" },
    ]
    render(<SkeletonLines lines={lines} />)
    expect(screen.getByText("Text")).toBeInTheDocument()
    expect(screen.getByText("Badge")).toBeInTheDocument()
    expect(screen.getByText("Progress")).toBeInTheDocument()
  })

  it("uses compact text styles for consecutive loading text lines", () => {
    const lines: ManifestLine[] = [
      { type: "text", label: "Used", scope: "overview" },
      { type: "text", label: "Left", scope: "overview" },
    ]
    render(<SkeletonLines lines={lines} />)

    const usedLabel = screen.getByText("Used")
    const leftLabel = screen.getByText("Left")

    expect(usedLabel).toHaveClass("text-xs")
    expect(leftLabel).toHaveClass("text-xs")
    expect(usedLabel.parentElement).toHaveClass("h-[18px]")
    expect(leftLabel.parentElement).toHaveClass("h-[18px]")

    const textGroup = usedLabel.closest(".space-y-1")
    expect(textGroup).toBeInTheDocument()
    expect(textGroup).toContainElement(leftLabel.parentElement)
  })

  it("falls back on unknown type", () => {
    const line = { type: "nope", label: "Fallback" } as unknown as ManifestLine
    render(<SkeletonLine line={line} />)
    expect(screen.getByText("Fallback")).toBeInTheDocument()
  })
})
