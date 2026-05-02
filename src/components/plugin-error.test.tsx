import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"
import { vi } from "vitest"
import { PluginError } from "@/components/plugin-error"

describe("PluginError", () => {
  it("renders message", () => {
    render(<PluginError message="Boom" />)
    expect(screen.getByText("Boom")).toBeInTheDocument()
  })

  it("formats backtick code in message", () => {
    render(<PluginError message="Check `config.json` file" />)
    expect(screen.getByText("config.json")).toBeInTheDocument()
  })

  it("renders retry action when provided", async () => {
    const onRetry = vi.fn()
    render(<PluginError message="Start Antigravity and try again." onRetry={onRetry} />)

    await userEvent.click(screen.getByRole("button", { name: "Retry" }))

    expect(onRetry).toHaveBeenCalledTimes(1)
  })
})
