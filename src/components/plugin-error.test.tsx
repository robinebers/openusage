import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { PluginError } from "@/components/plugin-error"

describe("PluginError", () => {
  it("renders message and retry action", async () => {
    const onRetry = vi.fn()
    render(<PluginError message="Boom" onRetry={onRetry} />)
    expect(screen.getByText("Boom")).toBeInTheDocument()
    await userEvent.click(screen.getByText("Retry"))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it("renders without retry", () => {
    render(<PluginError message="Nope" />)
    expect(screen.getByText("Nope")).toBeInTheDocument()
  })
})
