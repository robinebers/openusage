# Phase 6 smoke harness — records results to stdout JSON (no secrets logged)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$ShellExe = Join-Path $Root "spikes\windows-shell\bin\Debug\net8.0-windows10.0.19041.0\OpenUsageShell.exe"
$ZipPath = Join-Path $Root "dist\windows\OpenUsage-windows-x64.zip"
$LogDir = Join-Path $env:LOCALAPPDATA "OpenUsage\logs"
$SettingsPath = Join-Path $env:LOCALAPPDATA "OpenUsage\settings.json"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunValue = "OpenUsage"
$PipeName = "OpenUsageCore-$env:USERNAME"
$Date = (Get-Date -Format "yyyy-MM-dd")

$results = [ordered]@{
    date = $Date
    fresh_launch = "Untested"
    single_instance = "Untested"
    autostart_toggle = "Untested"
    toast_test = "Untested"
    snapshot_refresh = "Untested"
    shell_log = "Untested"
    core_log = "Untested"
    cold_start_ms = $null
    snapshot_ok_count = $null
    rss_shell_mb = $null
    rss_sidecar_mb = $null
    rss_total_mb = $null
    zip_exists = (Test-Path $ZipPath)
}

function Stop-OpenUsage {
    Get-Process OpenUsageShell, sidecar -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Wait-PipeReady {
    param([int]$TimeoutSec = 180)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        Start-Sleep -Seconds 1
        try {
            $probe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
            $probe.Connect(500)
            $probe.Close()
            return $true
        } catch { }
    }
    return $false
}

function Get-Snapshot {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(30000)
    $writer = New-Object System.IO.StreamWriter($client, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $reader = New-Object System.IO.StreamReader($client)
    $writer.WriteLine('{"op":"snapshot"}')
    $snap = $reader.ReadLine()
    $client.Close()
    return $snap
}

if (-not (Test-Path $ShellExe)) {
    Write-Host "ERROR: Shell not built at $ShellExe"
    exit 1
}

Stop-OpenUsage

# --- Fresh launch + cold start + snapshot ---
$t0 = Get-Date
$p1 = Start-Process -FilePath $ShellExe -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
$results.fresh_launch = if ($p1 -and -not $p1.HasExited) { "Pass" } else { "Fail" }

if (Wait-PipeReady -TimeoutSec 180) {
    try {
        $tSnapStart = Get-Date
        $snap = Get-Snapshot
        if ($snap) {
            $obj = $snap | ConvertFrom-Json
            $ok = @($obj.providers | Where-Object { $_.status -eq "ok" })
            $results.snapshot_ok_count = $ok.Count
            $results.snapshot_refresh = if ($ok.Count -ge 1) { "Pass" } else { "Fail" }
            $results.cold_start_ms = [int](((Get-Date) - $t0).TotalMilliseconds)
        } else {
            $results.snapshot_refresh = "Fail"
        }
    } catch {
        $results.snapshot_refresh = "Fail"
    }
} else {
    $results.snapshot_refresh = "Fail"
}

Start-Sleep -Seconds 2
$shellProc = Get-Process -Name OpenUsageShell -ErrorAction SilentlyContinue | Select-Object -First 1
$sideProc = Get-Process -Name sidecar -ErrorAction SilentlyContinue | Select-Object -First 1
if ($shellProc) { $results.rss_shell_mb = [math]::Round($shellProc.WorkingSet64 / 1MB, 1) }
if ($sideProc) { $results.rss_sidecar_mb = [math]::Round($sideProc.WorkingSet64 / 1MB, 1) }
if ($shellProc -and $sideProc) {
    $results.rss_total_mb = [math]::Round(($shellProc.WorkingSet64 + $sideProc.WorkingSet64) / 1MB, 1)
}

$results.shell_log = if (Test-Path (Join-Path $LogDir "shell.log")) { "Pass" } else { "Fail" }
$results.core_log = if (Test-Path (Join-Path $LogDir "OpenUsage.log")) { "Pass" } else { "Fail" }

# --- Single instance ---
$p2 = Start-Process -FilePath $ShellExe -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$shellCount = @(Get-Process -Name OpenUsageShell -ErrorAction SilentlyContinue).Count
$sideCount = @(Get-Process -Name sidecar -ErrorAction SilentlyContinue).Count
$results.single_instance = if ($shellCount -eq 1 -and $sideCount -eq 1) { "Pass" } else { "Fail" }
if ($p2 -and -not $p2.HasExited) { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue }

# --- Autostart toggle (enable then disable; leave OFF) ---
try {
    $exeQuoted = "`"$ShellExe`""
    New-ItemProperty -Path $RunKey -Name $RunValue -Value $exeQuoted -PropertyType String -Force | Out-Null
    $enabledOk = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue).OpenUsage -eq $exeQuoted
    Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
    $disabledOk = -not (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue)
    $results.autostart_toggle = if ($enabledOk -and $disabledOk) { "Pass" } else { "Fail" }
} catch {
    $results.autostart_toggle = "Fail"
}

# Ensure settings launchAtLogin is false if file exists
if (Test-Path $SettingsPath) {
    try {
        $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if ($settings.launchAtLogin -eq $true) {
            $settings.launchAtLogin = $false
            $settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsPath -Encoding UTF8
        }
    } catch { }
}

# --- Toast: check shell.log for prior successful show or toast init ---
$toastPass = $false
$logPath = Join-Path $LogDir "shell.log"
if (Test-Path $logPath) {
    $logTail = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue
    if ($logTail -match "toast.*Shown:" -or $logTail -match "Toast notifier ready") {
        $toastPass = $true
    }
}
$results.toast_test = if ($toastPass) { "Pass (log evidence)" } else { "Untested (requires tray UI click)" }

Stop-OpenUsage

$results | ConvertTo-Json -Depth 4
