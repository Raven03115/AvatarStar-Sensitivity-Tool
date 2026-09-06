param(
    [Parameter(Mandatory=$true)][string]$BackendBase64,
    [Parameter(Mandatory=$true)][string]$ExpectedBackendHash,
    [Parameter(Mandatory=$true)][string]$SessionDir,
    [string]$ToolVersion = '1.0',
    [string]$OriginalLocalAppData = '',
    [string]$OriginalAppData = '',
    [string]$OriginalUserProfile = '',
    [string]$OriginalUserSid = '',
    [Parameter(Mandatory=$true)][int]$FrontendPid,
    [Parameter(Mandatory=$true)][Int64]$FrontendStartTicks
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$enc950 = [System.Text.Encoding]::GetEncoding(950)
$resultFile = Join-Path $SessionDir 'result.txt'
$requestFile = Join-Path $SessionDir 'request.json'
$doneFile = Join-Path $SessionDir 'done.id'
$readyFile = Join-Path $SessionDir 'ready.flag'
$stopFile = Join-Path $SessionDir 'stop.flag'
$progressFile = Join-Path $SessionDir 'progress.txt'
$heartbeatFile = Join-Path $SessionDir 'worker.heartbeat'
$metaFile = Join-Path $SessionDir 'worker.meta.json'
$deadFile = Join-Path $SessionDir 'worker.dead'
$blockedFile = Join-Path $SessionDir 'blocked.flag'

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Convert-ScriptBytesToUtf8Text([byte[]]$Bytes) {
    if ($null -eq $Bytes) { throw 'Script bytes are missing.' }
    $offset = 0
    $count = $Bytes.Length
    if ($count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $offset = 3
        $count -= 3
    }
    return [System.Text.Encoding]::UTF8.GetString($Bytes, $offset, $count)
}

function Write-WorkerError([string]$Message, [string]$RequestId = '') {
    try {
        # Preserve the frontend's timeout/uncertain-state result if it has already locked the session.
        if ((Test-Path -LiteralPath $blockedFile -PathType Leaf) -and (Test-Path -LiteralPath $resultFile -PathType Leaf)) { return }
        $lines = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $lines.Add(('REQUESTID=' + $RequestId)) }
        $lines.Add('STATUS=ERROR')
        $lines.Add(('MESSAGE=' + (($Message -replace "`r|`n", ' '))))
        [System.IO.File]::WriteAllLines($resultFile, $lines, $enc950)
    } catch {}
}

function Touch-WorkerHeartbeat {
    try {
        [System.IO.File]::WriteAllText(
            $heartbeatFile,
            [DateTime]::UtcNow.Ticks.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            [System.Text.Encoding]::ASCII
        )
    } catch {}
}

function Frontend-IsAlive {
    try {
        $p = Get-Process -Id $FrontendPid -ErrorAction Stop
        return ($p.StartTime.ToUniversalTime().Ticks -eq $FrontendStartTicks)
    }
    catch { return $false }
}

try {
    if (-not (Test-Path -LiteralPath $SessionDir -PathType Container)) { exit 2 }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-WorkerError '管理員 Worker 未取得真正的 Administrator token。'
        exit 8
    }
    if (-not (Frontend-IsAlive)) { Write-WorkerError '可見 CMD 工作階段已不存在。'; exit 9 }

    # Backend arrived as already-hash-verified in-memory text from the elevated bootstrap.
    # Verify it again before creating the ScriptBlock, then never reopen Backend from disk.
    $backendBytes = [Convert]::FromBase64String($BackendBase64)
    if ((Get-Sha256Hex $backendBytes) -ne $ExpectedBackendHash.ToLowerInvariant()) {
        Write-WorkerError '管理員 Backend 記憶體完整性驗證失敗。'
        exit 10
    }
    $backendText = Convert-ScriptBytesToUtf8Text $backendBytes
    $backendScript = [ScriptBlock]::Create($backendText)

    $workerProcess = Get-Process -Id $PID -ErrorAction Stop
    $meta = [ordered]@{ Pid=$PID; StartTicks=$workerProcess.StartTime.ToUniversalTime().Ticks }
    [System.IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json -Compress), $Utf8NoBom)

    Remove-Item -LiteralPath $deadFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $blockedFile -Force -ErrorAction SilentlyContinue
    Touch-WorkerHeartbeat
    [System.IO.File]::WriteAllText($readyFile, 'READY', [System.Text.Encoding]::ASCII)
    $lastHeartbeat = [DateTime]::UtcNow.AddSeconds(-2)

    while ($true) {
        if (Test-Path -LiteralPath $stopFile -PathType Leaf) { break }
        if (-not (Frontend-IsAlive)) { break }

        if (([DateTime]::UtcNow - $lastHeartbeat).TotalMilliseconds -ge 750) {
            Touch-WorkerHeartbeat
            $lastHeartbeat = [DateTime]::UtcNow
        }

        if (-not (Test-Path -LiteralPath $requestFile -PathType Leaf)) {
            Start-Sleep -Milliseconds 100
            continue
        }

        if (Test-Path -LiteralPath $blockedFile -PathType Leaf) {
            Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
            Write-WorkerError '目前工作階段已因前一個不確定作業而鎖定；請重新啟動工具。'
            Start-Sleep -Milliseconds 100
            continue
        }

        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue

        $requestId = ''
        try {
            $raw = [System.IO.File]::ReadAllText($requestFile, $Utf8NoBom)
            $req = $raw | ConvertFrom-Json
            Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue

            $requestId = [string]$req.RequestId
            if ([string]::IsNullOrWhiteSpace($requestId)) { throw '要求缺少 RequestId。' }
            if (-not $req.Action) { throw '要求缺少 Action。' }
            if (-not (Frontend-IsAlive)) { throw '可見 CMD 工作階段已關閉。' }

            $invokeParams = @{
                Action = [string]$req.Action
                OutFile = $resultFile
                ProgressFile = $progressFile
                SessionDir = $SessionDir
                HeartbeatFile = $heartbeatFile
                OriginalLocalAppData = $OriginalLocalAppData
                OriginalAppData = $OriginalAppData
                OriginalUserProfile = $OriginalUserProfile
                OriginalUserSid = $OriginalUserSid
                FrontendPid = $FrontendPid
                FrontendStartTicks = $FrontendStartTicks
                RequestId = $requestId
                ToolVersion = $ToolVersion
            }
            if ($null -ne $req.Target) { $invokeParams['Target'] = [string]$req.Target }
            if ($null -ne $req.ConvertMode) { $invokeParams['ConvertMode'] = [string]$req.ConvertMode }
            if ($null -ne $req.Value) { $invokeParams['Value'] = [string]$req.Value }
            if ($null -ne $req.Zoom) { $invokeParams['Zoom'] = [string]$req.Zoom }

            & $backendScript @invokeParams
            if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) { Write-WorkerError '後端沒有回傳結果。' $requestId }
        }
        catch {
            Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($requestId)) {
                # Malformed IPC before a request identity is trustworthy: fail the whole worker session.
                Write-WorkerError $_.Exception.Message
                [System.IO.File]::WriteAllText($blockedFile, 'BLOCKED', [System.Text.Encoding]::ASCII)
                throw
            }
            Write-WorkerError $_.Exception.Message $requestId
        }

        Touch-WorkerHeartbeat
        if (-not [string]::IsNullOrWhiteSpace($requestId)) {
            try { [System.IO.File]::WriteAllText($doneFile, $requestId, [System.Text.Encoding]::ASCII) } catch {}
        }
        Start-Sleep -Milliseconds 100
    }
}
finally {
    try { [System.IO.File]::WriteAllText($deadFile, 'DEAD', [System.Text.Encoding]::ASCII) } catch {}
    Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $heartbeatFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue
}
