param(
    [Parameter(Mandatory=$true)][string]$SessionDir,
    [string]$ToolVersion = '1.0'
)

$ErrorActionPreference = 'Stop'
$Worker = Join-Path $PSScriptRoot 'AvatarStar_AdminWorker.ps1'
$Backend = Join-Path $PSScriptRoot 'AvatarStar_Backend.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

try {
    if (-not (Test-Path -LiteralPath $SessionDir -PathType Container)) { exit 2 }
    if (-not (Test-Path -LiteralPath $Worker -PathType Leaf)) { exit 3 }
    if (-not (Test-Path -LiteralPath $Backend -PathType Leaf)) { exit 4 }

    $parentPid = 0
    try {
        $me = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop
        $parentPid = [int]$me.ParentProcessId
    }
    catch {
        $me = Get-WmiObject Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop
        $parentPid = [int]$me.ParentProcessId
    }

    $frontend = Get-Process -Id $parentPid -ErrorAction Stop
    $frontendStartTicks = $frontend.StartTime.ToUniversalTime().Ticks
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # Pin the exact worker/backend bytes BEFORE UAC. The elevated bootstrap will only execute
    # files whose SHA-256 still matches these pre-elevation bytes, then passes Backend as text
    # in memory. This closes the verify-then-reopen race on a user-writable tool directory.
    $workerBytesBefore = [System.IO.File]::ReadAllBytes($Worker)
    $backendBytesBefore = [System.IO.File]::ReadAllBytes($Backend)
    $workerHash = Get-Sha256Hex $workerBytesBefore
    $backendHash = Get-Sha256Hex $backendBytesBefore

    $cfg = [ordered]@{
        Worker = [System.IO.Path]::GetFullPath($Worker)
        Backend = [System.IO.Path]::GetFullPath($Backend)
        WorkerHash = $workerHash
        BackendHash = $backendHash
        SessionDir = [System.IO.Path]::GetFullPath($SessionDir)
        ToolVersion = $ToolVersion
        OriginalLocalAppData = [string]$env:LOCALAPPDATA
        OriginalAppData = [string]$env:APPDATA
        OriginalUserProfile = [string]$env:USERPROFILE
        OriginalUserSid = [string]$sid
        FrontendPid = $parentPid
        FrontendStartTicks = $frontendStartTicks
    }
    $cfgJson = $cfg | ConvertTo-Json -Compress
    $cfgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cfgJson))

    foreach ($name in @('ready.flag','worker.heartbeat','worker.meta.json','worker.dead','stop.flag','blocked.flag')) {
        Remove-Item -LiteralPath (Join-Path $SessionDir $name) -Force -ErrorAction SilentlyContinue
    }

    # The immutable bootstrap configuration is embedded inside EncodedCommand. No writable
    # bootstrap file is read after elevation. Target/game paths are still sent later via file IPC.
    $command = @"
`$ErrorActionPreference = 'Stop'
function Get-HashHex([byte[]]`$b) {
    `$s = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString(`$s.ComputeHash(`$b))).Replace('-', '').ToLowerInvariant() }
    finally { `$s.Dispose() }
}
function Convert-ScriptBytesToUtf8Text([byte[]]`$b) {
    if (`$null -eq `$b) { throw 'Script bytes are missing.' }
    `$offset = 0
    `$count = `$b.Length
    if (`$count -ge 3 -and `$b[0] -eq 0xEF -and `$b[1] -eq 0xBB -and `$b[2] -eq 0xBF) {
        `$offset = 3
        `$count -= 3
    }
    return [System.Text.Encoding]::UTF8.GetString(`$b, `$offset, `$count)
}
`$cfgJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$cfgB64'))
`$cfg = `$cfgJson | ConvertFrom-Json
`$workerBytes = [System.IO.File]::ReadAllBytes([string]`$cfg.Worker)
`$backendBytes = [System.IO.File]::ReadAllBytes([string]`$cfg.Backend)
if ((Get-HashHex `$workerBytes) -ne ([string]`$cfg.WorkerHash).ToLowerInvariant()) { throw 'Worker integrity changed before elevation completed.' }
if ((Get-HashHex `$backendBytes) -ne ([string]`$cfg.BackendHash).ToLowerInvariant()) { throw 'Backend integrity changed before elevation completed.' }
`$workerText = Convert-ScriptBytesToUtf8Text `$workerBytes
`$backendB64 = [Convert]::ToBase64String(`$backendBytes)
`$workerScript = [ScriptBlock]::Create(`$workerText)
`$p = @{
    BackendBase64 = `$backendB64
    ExpectedBackendHash = [string]`$cfg.BackendHash
    SessionDir = [string]`$cfg.SessionDir
    ToolVersion = [string]`$cfg.ToolVersion
    OriginalLocalAppData = [string]`$cfg.OriginalLocalAppData
    OriginalAppData = [string]`$cfg.OriginalAppData
    OriginalUserProfile = [string]`$cfg.OriginalUserProfile
    OriginalUserSid = [string]`$cfg.OriginalUserSid
    FrontendPid = [int]`$cfg.FrontendPid
    FrontendStartTicks = [Int64]`$cfg.FrontendStartTicks
}
& `$workerScript @p
exit `$LASTEXITCODE
"@

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $process) { exit 5 }

    $ready = Join-Path $SessionDir 'ready.flag'
    $dead = Join-Path $SessionDir 'worker.dead'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ready -PathType Leaf) { exit 0 }
        if (Test-Path -LiteralPath $dead -PathType Leaf) { exit 6 }
        try { if ($process.HasExited) { exit 6 } } catch {}
        Start-Sleep -Milliseconds 100
    }
    exit 7
}
catch [System.ComponentModel.Win32Exception] {
    exit 1223
}
catch {
    exit 9
}
