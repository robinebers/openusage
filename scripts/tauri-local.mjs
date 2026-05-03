import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const bin = process.platform === "win32"
  ? path.join(root, "node_modules", ".bin", "tauri.exe")
  : path.join(root, "node_modules", ".bin", "tauri")

const args = process.argv.slice(2)
const shouldUseUnsignedLocalBuild =
  process.platform === "win32" &&
  args[0] === "build" &&
  !process.env.TAURI_SIGNING_PRIVATE_KEY &&
  !args.includes("--config") &&
  !args.includes("-c")

const finalArgs = shouldUseUnsignedLocalBuild
  ? [...args, "--config", "src-tauri/tauri.local.conf.json"]
  : args

const result = spawnSync(bin, finalArgs, {
  cwd: root,
  stdio: "inherit",
  shell: false,
})

if (result.error) {
  throw result.error
}

process.exit(result.status ?? 1)
