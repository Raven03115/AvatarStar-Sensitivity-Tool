param(
    [Parameter(Mandatory=$true)][string]$SessionDir,
    [Parameter(Mandatory=$true)][string]$Action
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$request = Join-Path $SessionDir 'request.json'
$tmp = Join-Path $SessionDir 'request.tmp'
$done = Join-Path $SessionDir 'done.id'
$result = Join-Path $SessionDir 'result.txt'
$progress = Join-Path $SessionDir 'progress.txt'
$ready = Join-Path $SessionDir 'ready.flag'
$heartbeat = Join-Path $SessionDir 'worker.heartbeat'
$metaFile = Join-Path $SessionDir 'worker.meta.json'
$activeFile = Join-Path $SessionDir 'active.id'
$blocked = Join-Path $SessionDir 'blocked.flag'

if (Test-Path -LiteralPath $blocked -PathType Leaf) { exit 20 }
if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) { exit 10 }
if (-not (Test-Path -LiteralPath $heartbeat -PathType Leaf)) { exit 11 }
if (-not (Test-Path -LiteralPath $metaFile -PathType Leaf)) { exit 12 }
if (Test-Path -LiteralPath $request -PathType Leaf) { exit 15 }

try {
    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc).TotalSeconds
    if ($age -gt 10) { exit 13 }
    $meta = ([System.IO.File]::ReadAllText($metaFile, $Utf8NoBom) | ConvertFrom-Json)
    $worker = Get-Process -Id ([int]$meta.Pid) -ErrorAction Stop
    if ($worker.StartTime.ToUniversalTime().Ticks -ne [Int64]$meta.StartTicks) { exit 14 }
}
catch { exit 14 }

$requestId = [Guid]::NewGuid().ToString('N')
Remove-Item -LiteralPath $done -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $progress -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
foreach ($oldCancel in @(Get-ChildItem -LiteralPath $SessionDir -Filter 'cancel.*.flag' -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $oldCancel.FullName -Force -ErrorAction SilentlyContinue
}

$obj = [ordered]@{
    RequestId = $requestId
    Action = $Action
    Target = $(if ($Action -eq 'Inspect') { [string]$env:AVATARSTAR_REQ_TARGET } else { '' })
    ConvertMode = [string]$env:AVATARSTAR_REQ_CONVERT
    Value = [string]$env:AVATARSTAR_REQ_VALUE
    Zoom = [string]$env:AVATARSTAR_REQ_ZOOM
}
[System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress), $Utf8NoBom)
[System.IO.File]::WriteAllText($activeFile, $requestId, [System.Text.Encoding]::ASCII)
Move-Item -LiteralPath $tmp -Destination $request -Force
exit 0
