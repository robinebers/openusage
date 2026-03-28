const { cpSync, readdirSync, rmSync } = require("fs")
const { join } = require("path")

const root = __dirname
const mockOnly = process.env.OPENUSAGE_WINDOWS_PLUGIN_MODE === "mock"
const exclude = new Set(mockOnly ? [] : ["mock"])
const srcDir = join(root, "plugins")
const dstDir = join(root, "src-tauri", "resources", "bundled_plugins")

rmSync(dstDir, { recursive: true, force: true })

const plugins = readdirSync(srcDir, { withFileTypes: true })
  .filter((d) => d.isDirectory() && !exclude.has(d.name))
  .filter((d) => !mockOnly || d.name === "mock")
  .map((d) => d.name)

for (const id of plugins) {
  cpSync(join(srcDir, id), join(dstDir, id), { recursive: true })
}

console.log(`Bundled ${plugins.length} plugins: ${plugins.join(", ")}`)
