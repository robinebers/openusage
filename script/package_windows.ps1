<#
.SYNOPSIS
  Packages the OpenUsage Windows spike into a self-contained zip.

.DESCRIPTION
  1. Builds the Swift sidecar (Release)
  2. Publishes the WPF shell as self-contained win-x64
  3. Copies sidecar.exe and Swift runtime DLLs (probed via dumpbin /dependents)
  4. Stages under dist/windows/OpenUsage/
  5. Produces dist/windows/OpenUsage-windows-x64.zip

  Signing is NOT performed — see docs/research/windows-phase5-findings.md.

.EXAMPLE
  .\script\package_windows.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$CoreDir = Join-Path $RootDir "spikes\windows-core"
$ShellDir = Join-Path $RootDir "spikes\windows-shell"
$DistRoot = Join-Path $RootDir "dist\windows"
$StageDir = Join-Path $DistRoot "OpenUsage"
$ZipPath = Join-Path $DistRoot "OpenUsage-windows-x64.zip"

$VcVars = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$DotNet = "C:\Program Files\dotnet\dotnet.exe"
if (-not (Test-Path $DotNet)) {
    $DotNet = "dotnet"
}

$SystemDllPrefixes = @(
    "KERNEL32", "ADVAPI32", "USER32", "SHELL32", "OLE32", "OLEAUT32", "WS2_32",
    "api-ms-win-crt", "api-ms-win-core"
)

function Initialize-SwiftEnvironment {
    $sdkRoot = [Environment]::GetEnvironmentVariable("SDKROOT", "User")
    if ([string]::IsNullOrWhiteSpace($sdkRoot)) {
        throw "SDKROOT user environment variable is not set."
    }
    $env:SDKROOT = $sdkRoot

    $toolchainRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains"
    $runtimeRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"
    $script:ToolchainBin = (Get-ChildItem -Path $toolchainRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "usr\bin" })
    $script:RuntimeBin = (Get-ChildItem -Path $runtimeRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "usr\bin" })

    if (-not $script:ToolchainBin -or -not (Test-Path $script:ToolchainBin)) {
        throw "Swift toolchain bin directory not found."
    }
    if (-not $script:RuntimeBin -or -not (Test-Path $script:RuntimeBin)) {
        throw "Swift runtime bin directory not found."
    }

    $env:Path = "$($script:ToolchainBin);$($script:RuntimeBin);" + $env:Path
}

function Get-DumpBinPath {
    $candidates = @()
    if ($VcVars) {
        $vsRoot = Split-Path (Split-Path (Split-Path (Split-Path $VcVars -Parent) -Parent) -Parent) -Parent
        $candidates += Join-Path $vsRoot "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"
    }
    $candidates += "C:\Program Files*\Microsoft Visual Studio\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"
    foreach ($pattern in $candidates) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-SidecarDependencies {
    param([string] $SidecarExe)

    $dumpbin = Get-DumpBinPath
    if ($dumpbin) {
        Write-Host "==> probing dependencies with dumpbin"
        $output = & $dumpbin /nologo /dependents $SidecarExe 2>&1 | Out-String
        $dlls = [regex]::Matches($output, '(?m)^\s+(\S+\.dll)\s*$') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object {
                $name = $_
                -not ($SystemDllPrefixes | Where-Object { $name -like "$_*" })
            } |
            Select-Object -Unique
        if ($dlls.Count -gt 0) {
            return $dlls
        }
    }

    Write-Host "==> dumpbin unavailable or empty; copying all Swift runtime DLLs"
    return Get-ChildItem -Path $script:RuntimeBin -Filter "*.dll" | Select-Object -ExpandProperty Name
}

function Build-SidecarRelease {
    if (-not $VcVars) {
        throw "vcvars64.bat not found."
    }
    Write-Host "==> swift build sidecar (release)"
    $cmd = "`"$VcVars`" && cd /d `"$CoreDir`" && swift build --product sidecar -c release"
    cmd /s /c $cmd | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "swift build --product sidecar failed"
    }

    $sidecar = Join-Path $CoreDir ".build\x86_64-unknown-windows-msvc\release\sidecar.exe"
    if (-not (Test-Path $sidecar)) {
        throw "Missing release sidecar: $sidecar"
    }
    return ,$sidecar
}

function Publish-Shell {
    Write-Host "==> dotnet publish (self-contained win-x64)"
    $publishDir = Join-Path $ShellDir "bin\publish\win-x64"
    if (Test-Path $publishDir) {
        Remove-Item -Recurse -Force $publishDir
    }

    & $DotNet publish $ShellDir `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=false `
        -o $publishDir | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed"
    }
    return ,$publishDir
}

function Stage-Package {
    param(
        [string] $PublishDir,
        [string] $SidecarExe
    )

    if (Test-Path $StageDir) {
        Remove-Item -Recurse -Force $StageDir
    }
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

    Write-Host "==> staging to $StageDir"
    Copy-Item -Path (Join-Path $PublishDir "*") -Destination $StageDir -Recurse -Force
    Copy-Item -Path $SidecarExe -Destination (Join-Path $StageDir "sidecar.exe") -Force

    $deps = Get-SidecarDependencies -SidecarExe $SidecarExe
    $copied = 0
    foreach ($dll in $deps) {
        $src = Join-Path $script:RuntimeBin $dll
        if (-not (Test-Path $src)) {
            $src = Join-Path $script:ToolchainBin $dll
        }
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $StageDir $dll) -Force
            $copied++
        } else {
            Write-Warning "Dependency not found in Swift runtime: $dll"
        }
    }
    Write-Host "==> copied $copied sidecar dependency DLL(s)"

    if (Test-Path $ZipPath) {
        Remove-Item -Force $ZipPath
    }
    Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $ZipPath -Force
    Write-Host "==> created $ZipPath"
}

Initialize-SwiftEnvironment
$sidecarExe = Build-SidecarRelease
$publishDir = Publish-Shell
Stage-Package -PublishDir $publishDir -SidecarExe $sidecarExe

Write-Host "==> package complete"
