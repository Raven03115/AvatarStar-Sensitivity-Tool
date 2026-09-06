param([Parameter(Mandatory=$true)][string]$SessionDir)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    $ready = Join-Path $SessionDir 'ready.flag'
    $heartbeat = Join-Path $SessionDir 'worker.heartbeat'
    $metaFile = Join-Path $SessionDir 'worker.meta.json'
    $blocked = Join-Path $SessionDir 'blocked.flag'
    if (Test-Path -LiteralPath $blocked -PathType Leaf) { exit 6 }
    if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) { exit 1 }
    if (-not (Test-Path -LiteralPath $heartbeat -PathType Leaf)) { exit 2 }
    if (-not (Test-Path -LiteralPath $metaFile -PathType Leaf)) { exit 3 }
    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc).TotalSeconds
    if ($age -gt 10) { exit 4 }
    $meta = ([System.IO.File]::ReadAllText($metaFile, $Utf8NoBom) | ConvertFrom-Json)
    $worker = Get-Process -Id ([int]$meta.Pid) -ErrorAction Stop
    if ($worker.StartTime.ToUniversalTime().Ticks -ne [Int64]$meta.StartTicks) { exit 5 }
    exit 0
}
catch { exit 5 }
