<#
.SYNOPSIS
  Builds and launches the OpenUsage Windows spike (WPF shell + Swift sidecar).

.DESCRIPTION
  Mirrors the spirit of script/build_and_run.sh for the Phase 5 Windows spike:
    1. Kill any running OpenUsageShell / sidecar processes
    2. Build the Swift sidecar (vcvars64 + SDKROOT per docs/research/windows-toolchain.md)
    3. Build the WPF shell with dotnet
    4. Launch OpenUsageShell.exe from the build output
    5. Optionally verify the process is running

  Dev builds use Debug configuration and do not check for updates (UpdateChecker uses a
  placeholder gh-pages feed; no installer is produced here).

.PARAMETER Mode
  run     — build, launch, and exit (default)
  build   — build only, do not launch
  verify  — build, launch, wait briefly, exit 1 if OpenUsageShell is not running

.EXAMPLE
  .\script\build_and_run.ps1

.EXAMPLE
  .\script\build_and_run.ps1 verify
#>
param(
    [ValidateSet("run", "build", "verify")]
    [string] $Mode = "run",

    [ValidateSet("Debug", "Release")]
    [string] $Configuration = "Debug"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$CoreDir = Join-Path $RootDir "spikes\windows-core"
$ShellDir = Join-Path $RootDir "spikes\windows-shell"
$ShellExe = Join-Path $ShellDir "bin\$Configuration\net8.0-windows10.0.19041.0\OpenUsageShell.exe"

$VcVars = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$DotNet = "C:\Program Files\dotnet\dotnet.exe"
if (-not (Test-Path $DotNet)) {
    $DotNet = "dotnet"
}

function Stop-OpenUsageProcesses {
    foreach ($name in @("OpenUsageShell", "sidecar")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "==> stopping $($_.ProcessName) pid=$($_.Id)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
}

function Initialize-SwiftEnvironment {
    $sdkRoot = [Environment]::GetEnvironmentVariable("SDKROOT", "User")
    if ([string]::IsNullOrWhiteSpace($sdkRoot)) {
        throw "SDKROOT user environment variable is not set. Re-run the Swift installer or set SDKROOT manually."
    }
    $env:SDKROOT = $sdkRoot

    $toolchainRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains"
    $runtimeRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"
    $toolchainBin = (Get-ChildItem -Path $toolchainRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "usr\bin" })
    $runtimeBin = (Get-ChildItem -Path $runtimeRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "usr\bin" })

    if (-not $toolchainBin -or -not (Test-Path $toolchainBin)) {
        throw "Swift toolchain bin directory not found under $toolchainRoot"
    }

    $pathParts = @($toolchainBin)
    if ($runtimeBin -and (Test-Path $runtimeBin)) {
        $pathParts += $runtimeBin
    }
    $env:Path = ($pathParts -join ";") + ";" + $env:Path
}

function Build-Sidecar {
    if (-not $VcVars) {
        throw "vcvars64.bat not found. Install VS 2022 Build Tools with the C++ workload."
    }

    $swiftConfig = if ($Configuration -eq "Release") { "release" } else { "debug" }
    Write-Host "==> swift build sidecar ($swiftConfig)"
    $cmd = "`"$VcVars`" && cd /d `"$CoreDir`" && swift build --product sidecar -c $swiftConfig"
    cmd /s /c $cmd | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "swift build --product sidecar failed with exit code $LASTEXITCODE"
    }
}

function Build-Shell {
    Write-Host "==> dotnet build ($Configuration)"
    & $DotNet build $ShellDir -c $Configuration --no-restore:$false
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path $ShellExe)) {
        throw "Missing built shell binary: $ShellExe"
    }
}

function Start-OpenUsageShell {
    Write-Host "==> launching $ShellExe"
    Start-Process -FilePath $ShellExe -WorkingDirectory (Split-Path $ShellExe -Parent)
}

function Test-OpenUsageRunning {
    Start-Sleep -Seconds 2
    $proc = Get-Process -Name "OpenUsageShell" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "==> running (pid=$($proc.Id))"
        return $true
    }
    Write-Host "==> OpenUsageShell is not running" -ForegroundColor Red
    return $false
}

Stop-OpenUsageProcesses
Initialize-SwiftEnvironment
Build-Sidecar
Build-Shell

switch ($Mode) {
    "build" {
        Write-Host "==> build complete"
    }
    "verify" {
        Start-OpenUsageShell
        if (-not (Test-OpenUsageRunning)) {
            exit 1
        }
    }
    default {
        Start-OpenUsageShell
        Write-Host "==> launched OpenUsageShell"
    }
}
