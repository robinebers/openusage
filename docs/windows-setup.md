# Windows Setup

OpenUsage can be built and run on Windows with the standard Tauri 2 Windows toolchain.

## Prerequisites

- Windows 10 or Windows 11, 64-bit
- Rust and Cargo from [rustup.rs](https://rustup.rs/)
- Bun from [bun.sh](https://bun.sh/)
- Visual Studio Build Tools 2022 with the **Desktop development with C++** workload
- Microsoft Edge WebView2 Runtime
- LLVM, so `rquickjs-sys` can find `libclang.dll`
- Git

On a fresh machine, install the native dependencies first:

1. Install Visual Studio Build Tools 2022 from <https://visualstudio.microsoft.com/visual-cpp-build-tools/>.
2. Select **Desktop development with C++**.
3. Install LLVM from <https://github.com/llvm/llvm-project/releases> or with `winget install LLVM.LLVM`.
4. Install Rust with rustup and Bun with the Bun installer.
5. Confirm WebView2 is installed in Windows Apps settings, or install it from <https://developer.microsoft.com/en-us/microsoft-edge/webview2/>.

## Build Environment

Run Rust/Tauri commands from a Visual Studio developer environment, and expose LLVM's `libclang.dll`:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsinstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devcmd = Join-Path $vsinstall "Common7\Tools\VsDevCmd.bat"
$cargoPath = "$env:USERPROFILE\.cargo\bin"
$llvmBin = "C:\Program Files\LLVM\bin"

cmd.exe /d /s /c "call `"$devcmd`" -arch=x64 -host_arch=x64 && set `"PATH=$cargoPath;$llvmBin;%PATH%`" && set `"LIBCLANG_PATH=$llvmBin`" && cargo check --manifest-path src-tauri/Cargo.toml"
```

## Development

```powershell
bun install
bun run bundle:plugins
bun run tauri dev
```

The Windows tray behavior differs from macOS:

- Left-click toggles the usage panel.
- Right-click opens the tray menu.
- The panel is positioned near the Windows taskbar and clamped to the current monitor.
- Application data is stored under the Windows app data directory managed by Tauri.

## Production Build

```powershell
bun run tauri build --no-sign
```

The Windows bundles are emitted under:

```text
src-tauri/target/release/bundle/
```

The project has updater signing enabled. Local unsigned installer builds should pass `--no-sign`, which produces MSI/NSIS bundles and skips updater signing. Maintainer release builds should omit `--no-sign` and provide `TAURI_SIGNING_PRIVATE_KEY` so updater artifacts are signed.

## Tested Windows Configuration

- Windows Pro, build 26200.8328, 64-bit
- Rust `1.95.0`
- Cargo `1.95.0`
- Bun `1.3.11`
- Git `2.52.0.windows.1`
- LLVM/clang `22.1.5`
- WebView2 Runtime `147.0.3912.98`
