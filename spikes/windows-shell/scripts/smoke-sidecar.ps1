# Smoke-test sidecar IPC and log redacted snapshot
$sidecar = "c:\Users\yildi\Repos\openusage\spikes\windows-core\.build\x86_64-unknown-windows-msvc\debug\sidecar.exe"
$pipeName = "OpenUsageCore-$env:USERNAME"
$log = "c:\Users\yildi\Repos\openusage\docs\research\windows-phase3-snapshot-log.json"

if (-not (Test-Path $sidecar)) { Write-Error "sidecar not built"; exit 1 }

$proc = Start-Process -FilePath $sidecar -PassThru -WindowStyle Hidden
Write-Host "Waiting for sidecar bootstrap (live refresh may take ~30s)..."
$connected = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    try {
        $probe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $probe.Connect(500)
        $probe.Close()
        $connected = $true
        break
    } catch { }
}
if (-not $connected) { Write-Warning "Pipe not ready after 60s; attempting connect anyway" }

try {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(30000)
    $writer = New-Object System.IO.StreamWriter($client, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $reader = New-Object System.IO.StreamReader($client)

    $writer.WriteLine('{"op":"ping"}')
    $pong = $reader.ReadLine()
    Write-Host "PONG: $pong"

    $writer.WriteLine('{"op":"snapshot"}')
    $snap = $reader.ReadLine()
    $snap | Out-File -Encoding utf8 $log
    Write-Host "Snapshot written to $log"

    $obj = $snap | ConvertFrom-Json
    foreach ($p in $obj.providers) {
        Write-Host "--- $($p.displayName) plan=$($p.plan) status=$($p.status) creds=$($p.credentialsFound)"
        foreach ($m in $p.metricLines) { Write-Host "    $($m.display)" }
    }
} finally {
    if ($client) { $client.Close() }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}
