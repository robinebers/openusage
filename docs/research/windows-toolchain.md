# Windows Toolchain Notes (Phase 0)

Status: Recorded 2026-07-10 on the Phase 0 Windows machine (`win32`, PowerShell).

## Swift Toolchain

| Item | Value |
|---|---|
| Install method | `winget install --id Swift.Toolchain -e --accept-source-agreements --accept-package-agreements` |
| Result | **Success** (exit code 0, ~8.4 minutes) |
| Swift version | **6.3.3** (`swift-6.3.3-RELEASE`) |
| Target triple | `x86_64-unknown-windows-msvc` |
| Install location | `%LOCALAPPDATA%\Programs\Swift\Toolchains\6.3.3+Asserts\` |
| Runtime | `%LOCALAPPDATA%\Programs\Swift\Runtimes\6.3.3\` |

`swift --version` works after refreshing PATH (winget adds the toolchain and runtime `usr\bin` directories).

### Winget auto-installed dependencies

| Package | Version | Notes |
|---|---|---|
| Python 3.10 | 3.10.11 | Required by Swift Windows toolchain scripts |
| Microsoft.VCRedist.2015+.x64 | 14.44.35211.0 | Already present; winget satisfied the dependency |

## MSVC prerequisites (RESOLVED same day)

Swift on Windows targets **MSVC** and requires the Visual Studio / Windows SDK toolchain. Initially
missing on this machine (`swift build` → `toolchain is invalid: could not find CLI tool 'link'`);
resolved by installing **VS 2022 Build Tools 17.14** with the C++ workload:

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements `
  --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

(~10 minutes, exit code 0, no elevation prompt blocked it.)

**Build environment requirements** (both needed):

1. VS developer environment: run inside `vcvars64.bat` / Developer PowerShell so `link.exe` is on PATH.
   Setting PATH alone is NOT enough — SwiftPM probes the environment vcvars sets up.
2. `SDKROOT` user environment variable (set by the Swift installer) must be present in the shell,
   otherwise: `unable to load standard library for target 'x86_64-unknown-windows-msvc'`.

Working invocation from a plain PowerShell:

```powershell
$env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT","User")
cmd /s /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`" && swift build && swift test"
```

Result in `spikes/windows-core/`: **Build complete!**, **98/98 tests pass**.

## Manual install steps (reference)

Per [Swift on Windows getting started](https://www.swift.org/install/windows/):

1. **Install Visual Studio 2022** (Community is fine) or **Build Tools for Visual Studio 2022** with:
   - Workload: **Desktop development with C++**
   - Individual components: **MSVC v143**, **Windows 10/11 SDK** (latest)
2. Open a **Developer PowerShell for VS 2022** (or run `VsDevCmd.bat`) so `link.exe`, `cl.exe`, and SDK paths are on PATH.
3. Verify:
   ```powershell
   where link
   swift --version
   ```
4. Build the spike:
   ```powershell
   cd spikes\windows-core
   swift build
   swift test
   ```

Alternative one-liner (requires elevation / user approval):

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools -e `
  --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

## Install caveats

- **Elevation:** The Swift installer and VS Build Tools may prompt for admin rights; winget succeeded without elevation on this machine for Swift itself.
- **PATH refresh:** New shells may be required after install for `swift` and VS tools to appear on PATH.
- **ARM64:** Only x64 toolchain was installed; ARM64 Swift for Windows status not evaluated in Phase 0.
- **Python:** Winget pulled Python 3.10 as a Swift dependency; no separate action needed.
- **Runtime vs toolchain:** Both `%LOCALAPPDATA%\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin` and `...\Runtimes\6.3.3\usr\bin` must be on PATH (winget handles this).

## Next verification (after VS install)

1. `swift build` in `spikes/windows-core/`
2. `swift test` — expect Grok/pricing/scanner tests to exercise bundled JSON resources via `Bundle.module`
3. Optional live Grok pass: ensure `%USERPROFILE%\.grok\auth.json` exists and run a small harness calling `GrokProvider.refresh()` (Phase 0 task 2 full criterion)
