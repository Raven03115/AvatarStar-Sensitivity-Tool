param(
    [Parameter(Mandatory=$true)][string]$SessionDir,
    [int]$TimeoutSeconds = 1800
)

$progressFile = Join-Path $SessionDir 'progress.txt'
$doneFile = Join-Path $SessionDir 'done.id'
$resultFile = Join-Path $SessionDir 'result.txt'
$readyFile = Join-Path $SessionDir 'ready.flag'
$heartbeatFile = Join-Path $SessionDir 'worker.heartbeat'
$metaFile = Join-Path $SessionDir 'worker.meta.json'
$activeFile = Join-Path $SessionDir 'active.id'
$blockedFile = Join-Path $SessionDir 'blocked.flag'
$enc950 = [System.Text.Encoding]::GetEncoding(950)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $enc950 } catch {}

function Read-State {
    $percent = 0; $stage = '準備中'
    try {
        if (Test-Path -LiteralPath $progressFile -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($progressFile, $enc950)) {
                if ($line -match '^PERCENT=(\d+)$') { $percent = [Math]::Max(0, [Math]::Min(100, [int]$matches[1])) }
                elseif ($line -match '^STAGE=(.*)$') { $stage = $matches[1] }
            }
        }
    } catch {}
    return @($percent, $stage)
}

function Write-Failure([string]$RequestId, [string]$Message) {
    try {
        [System.IO.File]::WriteAllLines($resultFile, @(
            ('REQUESTID=' + $RequestId), 'STATUS=ERROR', ('MESSAGE=' + $Message)
        ), $enc950)
    } catch {}
}

function Draw-ProgressLine([int]$Percent, [string]$Stage) {
    # Keep the line short enough that CJK stage text cannot wrap in the
    # 110-column CMD window. Wrapping a carriage-return line causes the
    # progress display to look like rapid scrolling.
    $width = 20
    $filled = [Math]::Floor(($Percent / 100.0) * $width)
    $filled = [Math]::Max(0, [Math]::Min($width, $filled))
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    if ([string]::IsNullOrWhiteSpace($Stage)) { $Stage = '準備中' }
    if ($Stage.Length -gt 20) { $Stage = $Stage.Substring(0, 20) }
    $line = ('                     [{0}] {1,3}%  {2}' -f $bar, $Percent, $Stage)
    $clearWidth = 100
    try { $clearWidth = [Math]::Max(1, [Math]::Min(100, [Console]::BufferWidth - 1)) } catch {}
    [Console]::Write("`r" + (' ' * $clearWidth) + "`r" + $line)
}

function Worker-IsHealthy {
    try {
        if (Test-Path -LiteralPath $blockedFile -PathType Leaf) { return $false }
        if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $metaFile -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $heartbeatFile -PathType Leaf)) { return $false }
        $meta = ([System.IO.File]::ReadAllText($metaFile, $Utf8NoBom) | ConvertFrom-Json)
        $p = Get-Process -Id ([int]$meta.Pid) -ErrorAction Stop
        if ($p.StartTime.ToUniversalTime().Ticks -ne [Int64]$meta.StartTicks) { return $false }
        $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $heartbeatFile).LastWriteTimeUtc).TotalSeconds
        return ($age -le 60)
    } catch { return $false }
}

if (-not (Test-Path -LiteralPath $activeFile -PathType Leaf)) {
    Write-Failure '' '找不到目前要求的 RequestId。'
    exit 2
}
$requestId = [System.IO.File]::ReadAllText($activeFile).Trim()
if ([string]::IsNullOrWhiteSpace($requestId)) { Write-Failure '' '目前要求的 RequestId 無效。'; exit 3 }

$lastProgressKey = ''
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false
$workerFailed = $false

while ($true) {
    $doneId = ''
    try { if (Test-Path -LiteralPath $doneFile -PathType Leaf) { $doneId = [System.IO.File]::ReadAllText($doneFile).Trim() } } catch {}
    if ($doneId -eq $requestId) { break }

    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        $timedOut = $true
        try { [System.IO.File]::WriteAllText((Join-Path $SessionDir ('cancel.' + $requestId + '.flag')), 'CANCEL', [System.Text.Encoding]::ASCII) } catch {}
        break
    }
    if (-not (Worker-IsHealthy)) { $workerFailed = $true; break }

    $state = Read-State
    $percent = [int]$state[0]; $stage = [string]$state[1]
    $progressKey = ('{0}|{1}' -f $percent, $stage)
    if ($progressKey -ne $lastProgressKey) {
        Draw-ProgressLine -Percent $percent -Stage $stage
        $lastProgressKey = $progressKey
    }
    Start-Sleep -Milliseconds 120
}

if ($timedOut) {
    # Give cooperative cancellation / rollback a short grace period. If it cannot settle, block the session.
    $grace = [Diagnostics.Stopwatch]::StartNew()
    while ($grace.Elapsed.TotalSeconds -lt 30) {
        $doneId = ''
        try { if (Test-Path -LiteralPath $doneFile -PathType Leaf) { $doneId = [System.IO.File]::ReadAllText($doneFile).Trim() } } catch {}
        if ($doneId -eq $requestId) { $timedOut = $false; break }
        if (-not (Worker-IsHealthy)) { break }
        Start-Sleep -Milliseconds 150
    }
    $grace.Stop()
    if ($timedOut) {
        try { [System.IO.File]::WriteAllText($blockedFile, 'BLOCKED', [System.Text.Encoding]::ASCII) } catch {}
        Write-Failure $requestId '管理員後端作業逾時且無法確認已安全結束；本工作階段已鎖定，請重新啟動工具。'
    }
}
elseif ($workerFailed) {
    try { [System.IO.File]::WriteAllText($blockedFile, 'BLOCKED', [System.Text.Encoding]::ASCII) } catch {}
    Write-Failure $requestId '管理員 Worker 已停止或 heartbeat 逾時；本工作階段已鎖定，請重新啟動工具。'
}

$sw.Stop()

# Reject stale/mismatched result files even if a stale done marker somehow survived.
if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
    try {
        $resultRequestId = ''
        foreach ($line in [System.IO.File]::ReadAllLines($resultFile, $enc950)) {
            if ($line -match '^REQUESTID=(.*)$') { $resultRequestId = $matches[1]; break }
        }
        if ($resultRequestId -ne $requestId) {
            [System.IO.File]::WriteAllText($blockedFile, 'BLOCKED', [System.Text.Encoding]::ASCII)
            Write-Failure $requestId '後端結果 RequestId 不一致；為避免套用上一個要求的結果，本工作階段已鎖定。'
        }
    }
    catch {
        [System.IO.File]::WriteAllText($blockedFile, 'BLOCKED', [System.Text.Encoding]::ASCII)
        Write-Failure $requestId '無法驗證後端結果 RequestId；本工作階段已鎖定。'
    }
}
$state = Read-State
$percent = [int]$state[0]; $stage = [string]$state[1]
if ([string]::IsNullOrWhiteSpace($stage)) { $stage = '完成' }
Draw-ProgressLine -Percent $percent -Stage $stage
[Console]::WriteLine()
exit 0
