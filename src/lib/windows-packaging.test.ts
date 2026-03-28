import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

const repoRoot = resolve(import.meta.dirname, "..", "..")

function readRepoFile(relativePath: string) {
  return readFileSync(resolve(repoRoot, relativePath), "utf8")
}

describe("windows packaging", () => {
  it("targets MSI-only bundling in tauri config", () => {
    const tauriConfig = JSON.parse(readRepoFile("src-tauri/tauri.conf.json"))

    expect(tauriConfig.bundle.targets).toBe("msi")
    expect(tauriConfig.bundle.macOS).toBeUndefined()
  })

  it("publishes MSI artifacts without updater or signing assumptions", () => {
    const publishWorkflow = readRepoFile(".github/workflows/publish.yml")

    expect(publishWorkflow).toContain("--bundles msi")
    expect(publishWorkflow).toContain("--no-sign")
    expect(publishWorkflow).not.toContain("nsis")
    expect(publishWorkflow).not.toContain("latest.json")
  })
})
