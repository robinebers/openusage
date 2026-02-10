import { describe, expect, it } from "vitest"
import {
  buildAccountOptionsByPlugin,
  filterCliProxySelectionsForProbe,
  LOCAL_ACCOUNT_VALUE,
  mapAuthProviderToPluginId,
  toCliProxyConfigView,
} from "@/lib/cliproxy-ui"

describe("cliproxy-ui", () => {
  it("normalizes config payload safely", () => {
    expect(toCliProxyConfigView(null)).toEqual({ configured: false, baseUrl: null })
    expect(toCliProxyConfigView({ configured: true, baseUrl: "http://localhost:8317" })).toEqual({
      configured: true,
      baseUrl: "http://localhost:8317",
    })
  })

  it("maps provider aliases", () => {
    expect(mapAuthProviderToPluginId("anthropic")).toBe("claude")
    expect(mapAuthProviderToPluginId(" codex ")).toBe("codex")
  })

  it("builds account options with local account first", () => {
    const options = buildAccountOptionsByPlugin([
      {
        id: "1",
        name: "codex-main.json",
        provider: "codex",
        email: "main@example.com",
        authIndex: "idx-1",
        disabled: false,
        unavailable: false,
      },
      {
        id: "2",
        name: "claude-alt.json",
        provider: "anthropic",
        email: null,
        authIndex: "idx-2",
        disabled: false,
        unavailable: false,
      },
      {
        id: "3",
        name: "skip.txt",
        provider: "codex",
        disabled: false,
        unavailable: false,
      },
    ])

    expect(options.codex[0]).toEqual({ value: LOCAL_ACCOUNT_VALUE, label: "Local account" })
    expect(options.codex.some((item) => item.value === "idx-1")).toBe(true)
    expect(options.claude.some((item) => item.value === "idx-2")).toBe(true)
  })

  it("filters selections passed to backend probe", () => {
    expect(
      filterCliProxySelectionsForProbe({
        codex: LOCAL_ACCOUNT_VALUE,
        claude: "idx-c",
        cursor: "idx-x",
        kimi: "",
      })
    ).toEqual({ claude: "idx-c" })
  })
})
