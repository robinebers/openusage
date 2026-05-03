import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
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
})
