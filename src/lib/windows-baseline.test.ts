import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

const repoRoot = resolve(import.meta.dirname, "..", "..")

function readRepoFile(relativePath: string) {
  return readFileSync(resolve(repoRoot, relativePath), "utf8")
}

describe("windows baseline", () => {
  it("forks the app identity and removes updater metadata from tauri config", () => {
    const tauriConfig = JSON.parse(readRepoFile("src-tauri/tauri.conf.json"))

    expect(tauriConfig.productName).toBe("OpenUsage Windows")
    expect(tauriConfig.identifier).toBe("com.rfara.openusagewindows")
    expect(tauriConfig.app.windows[0].title).toBe("OpenUsage Windows")
    expect(tauriConfig.app.macOSPrivateApi).toBeUndefined()
    expect(tauriConfig.bundle.createUpdaterArtifacts).toBe(false)
    expect(tauriConfig.plugins?.updater).toBeUndefined()
  })

  it("keeps the repo on Bun while removing telemetry and updater packages", () => {
    const packageJson = JSON.parse(readRepoFile("package.json"))

    expect(packageJson.name).toBe("openusage-windows")
    expect(packageJson.scripts.bundlePlugins ?? packageJson.scripts["bundle:plugins"]).toBeDefined()
    expect(packageJson.dependencies["@aptabase/tauri"]).toBeUndefined()
    expect(packageJson.dependencies["@tauri-apps/plugin-updater"]).toBeUndefined()
  })

  it("targets windows-only workflows", () => {
    const ciWorkflow = readRepoFile(".github/workflows/ci.yml")
    const publishWorkflow = readRepoFile(".github/workflows/publish.yml")

    expect(ciWorkflow).toContain("runs-on: windows-latest")
    expect(ciWorkflow).not.toContain("ubuntu-latest")

    expect(publishWorkflow).toContain("platform: windows-latest")
    expect(publishWorkflow).not.toContain("macos-latest")
    expect(publishWorkflow).not.toContain("APPLE_")
    expect(publishWorkflow).not.toContain("includeUpdaterJson: true")
  })
})
