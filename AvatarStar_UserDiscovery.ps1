param(
    [Parameter(Mandatory=$true)][string]$BackendPath,
    [Parameter(Mandatory=$true)][string]$SessionDir,
    [Parameter(Mandatory=$true)][ValidateSet('Locate','Inspect')][string]$Action,
    [string]$ToolVersion = '1.0'
)

$ErrorActionPreference = 'Stop'
$enc950 = [System.Text.Encoding]::GetEncoding(950)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $enc950 } catch {}

$resultFile = Join-Path $SessionDir 'result.txt'
$progressFile = Join-Path $SessionDir 'progress.txt'
$diagnosticFile = Join-Path $PSScriptRoot 'AvatarStar_Detection_Diagnostic.txt'

function Get-ParentFrontendInfo {
    $parentPid = 0
    try {
        $me = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop
        $parentPid = [int]$me.ParentProcessId
    }
    catch {
        try {
            $me = Get-WmiObject Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop
            $parentPid = [int]$me.ParentProcessId
        }
        catch { $parentPid = 0 }
    }
    if ($parentPid -le 0) { return [PSCustomObject]@{ Pid=0; StartTicks=[Int64]0 } }
    try {
        $p = Get-Process -Id $parentPid -ErrorAction Stop
        return [PSCustomObject]@{ Pid=$parentPid; StartTicks=$p.StartTime.ToUniversalTime().Ticks }
    }
    catch { return [PSCustomObject]@{ Pid=0; StartTicks=[Int64]0 } }
}

function Read-ProgressState {
    $percent = 0
    $stage = '準備中'
    try {
        if (Test-Path -LiteralPath $progressFile -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($progressFile, $enc950)) {
                if ($line -match '^PERCENT=(\d+)$') { $percent = [Math]::Max(0, [Math]::Min(100, [int]$matches[1])) }
                elseif ($line -match '^STAGE=(.*)$') { $stage = [string]$matches[1] }
            }
        }
    } catch {}
    return [PSCustomObject]@{ Percent=$percent; Stage=$stage }
}

function Draw-Progress([int]$Percent, [string]$Stage) {
    # Keep the live status comfortably below the 110-column CMD width.
    # CJK characters occupy two console cells, so the old 108-character line
    # could wrap and turn each refresh into a new visible row.
    $width = 20
    $filled = [Math]::Floor(($Percent / 100.0) * $width)
    $filled = [Math]::Max(0, [Math]::Min($width, $filled))
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    if ([string]::IsNullOrWhiteSpace($Stage)) { $Stage = '準備中' }
    if ($Stage.Length -gt 20) { $Stage = $Stage.Substring(0, 20) }
    $line = ('                     [{0}] {1,3}%  {2}' -f $bar, $Percent, $Stage)

    # Clear and redraw one physical console line. Avoid PadRight(108): string
    # length is not the same as display-cell width for Chinese text.
    $clearWidth = 100
    try { $clearWidth = [Math]::Max(1, [Math]::Min(100, [Console]::BufferWidth - 1)) } catch {}
    [Console]::Write("`r" + (' ' * $clearWidth) + "`r" + $line)
}

function Write-DetectionDiagnostic([string]$Reason, [string]$Target) {
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('Avatar Star Sensitivity Tool - Detection Diagnostic')
        $lines.Add(('ToolVersion=' + $ToolVersion))
        $lines.Add(('TimeUtc=' + [DateTime]::UtcNow.ToString('o')))
        $lines.Add('DetectionContext=ORIGINAL_USER_NON_ELEVATED')
        $lines.Add(('Reason=' + (($Reason -replace "`r|`n", ' '))))
        $lines.Add(('Target=' + $Target))
        $lines.Add(('UserProfile=' + [string]$env:USERPROFILE))
        $lines.Add(('LocalAppData=' + [string]$env:LOCALAPPDATA))
        $lines.Add(('AppData=' + [string]$env:APPDATA))
        try { $lines.Add(('UserSid=' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) } catch { $lines.Add('UserSid=UNAVAILABLE') }
        $lines.Add('--- Discovery selection state ---')
        try {
            $trace = Join-Path $SessionDir 'discovery-last-candidate.txt'
            $lines.Add(('LastCandidateTraceExists=' + [string][System.IO.File]::Exists($trace)))
            if ([System.IO.File]::Exists($trace)) {
                $last = [System.IO.File]::ReadAllText($trace, $Utf8NoBom).Trim()
                $lines.Add(('LastCandidatePde=' + $last))
                $lines.Add(('LastCandidatePdeExists=' + [string][System.IO.File]::Exists($last)))
            }
        } catch { $lines.Add(('LastCandidateTraceError=' + ($_.Exception.Message -replace "`r|`n", ' '))) }
        try {
            $current = Join-Path $SessionDir 'current.json'
            $lines.Add(('CurrentJsonExists=' + [string][System.IO.File]::Exists($current)))
            if ([System.IO.File]::Exists($current)) {
                $rawCurrent = [System.IO.File]::ReadAllText($current, $Utf8NoBom)
                $savedCurrent = $rawCurrent | ConvertFrom-Json
                $savedPde = [string]$savedCurrent.Pde
                $lines.Add(('CurrentPde=' + $savedPde))
                $lines.Add(('CurrentPdeExists=' + [string][System.IO.File]::Exists($savedPde)))
            }
        } catch { $lines.Add(('CurrentJsonError=' + ($_.Exception.Message -replace "`r|`n", ' '))) }
        $lines.Add('--- Drives visible to original user ---')
        try {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                try {
                    $lines.Add(('Drive=' + $d.Name + ';Type=' + [string]$d.DriveType + ';Ready=' + [string]$d.IsReady))
                } catch {}
            }
        } catch {}
        try {
            foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                try { $lines.Add(('PSDrive=' + $d.Name + ';Root=' + [string]$d.Root)) } catch {}
            }
        } catch {}
        $lines.Add('--- Common AvatarStar.pde probes ---')
        $rels = @(
            '百變兵團\AvatarStar.pde',
            '917play\百變兵團\AvatarStar.pde',
            '917Play\百變兵團\AvatarStar.pde',
            'AvatarStar\AvatarStar.pde',
            'Avatar Star\AvatarStar.pde',
            'Games\百變兵團\AvatarStar.pde',
            'Game\百變兵團\AvatarStar.pde'
        )
        $roots = New-Object System.Collections.ArrayList
        try {
            foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                try {
                    $r = [string]$d.Root
                    if ([string]::IsNullOrWhiteSpace($r)) { continue }
                    $dup=$false; foreach($x in $roots){ if([string]$x -ieq $r){$dup=$true;break} }
                    if(-not $dup){ [void]$roots.Add($r) }
                } catch {}
            }
        } catch {}
        foreach ($r in $roots) {
            foreach ($rel in $rels) {
                try {
                    $p = Join-Path $r $rel
                    $lines.Add(('Probe=' + $p + ';Exists=' + [string][System.IO.File]::Exists($p)))
                } catch {}
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Target)) {
            $lines.Add('--- Manual target visibility ---')
            try { $lines.Add(('TargetExists=' + [string](Test-Path -LiteralPath $Target))) } catch { $lines.Add('TargetExists=ERROR') }
            try {
                if (Test-Path -LiteralPath $Target -PathType Container) {
                    $candidate = Join-Path $Target 'AvatarStar.pde'
                    $lines.Add(('TargetDirectPde=' + $candidate + ';Exists=' + [string][System.IO.File]::Exists($candidate)))
                }
            } catch {}
        }
        [System.IO.File]::WriteAllLines($diagnosticFile, $lines, $Utf8NoBom)
    } catch {}
}

try {
    if (-not (Test-Path -LiteralPath $BackendPath -PathType Leaf)) { throw 'Backend 不存在。' }
    if (-not (Test-Path -LiteralPath $SessionDir -PathType Container)) { throw '工作階段資料夾不存在。' }

    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue

    $frontend = Get-ParentFrontendInfo
    $sid = ''
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {}
    $target = ''
    if ($Action -eq 'Inspect') { $target = [string]$env:AVATARSTAR_USER_TARGET }

    $backendBytes = [System.IO.File]::ReadAllBytes($BackendPath)
    $offset = 0
    $count = $backendBytes.Length
    if ($count -ge 3 -and $backendBytes[0] -eq 0xEF -and $backendBytes[1] -eq 0xBB -and $backendBytes[2] -eq 0xBF) { $offset = 3; $count -= 3 }
    $backendText = [System.Text.Encoding]::UTF8.GetString($backendBytes, $offset, $count)

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($backendText)
    [void]$ps.AddParameter('Action', $Action)
    [void]$ps.AddParameter('Target', $target)
    [void]$ps.AddParameter('OutFile', $resultFile)
    [void]$ps.AddParameter('ProgressFile', $progressFile)
    [void]$ps.AddParameter('SessionDir', $SessionDir)
    [void]$ps.AddParameter('OriginalLocalAppData', [string]$env:LOCALAPPDATA)
    [void]$ps.AddParameter('OriginalAppData', [string]$env:APPDATA)
    [void]$ps.AddParameter('OriginalUserProfile', [string]$env:USERPROFILE)
    [void]$ps.AddParameter('OriginalUserSid', [string]$sid)
    [void]$ps.AddParameter('FrontendPid', [int]$frontend.Pid)
    [void]$ps.AddParameter('FrontendStartTicks', [Int64]$frontend.StartTicks)
    [void]$ps.AddParameter('ToolVersion', $ToolVersion)

    $async = $ps.BeginInvoke()
    $lastProgressKey = ''
    while (-not $async.IsCompleted) {
        $s = Read-ProgressState
        $progressKey = ('{0}|{1}' -f [int]$s.Percent, [string]$s.Stage)
        if ($progressKey -ne $lastProgressKey) {
            Draw-Progress -Percent ([int]$s.Percent) -Stage ([string]$s.Stage)
            $lastProgressKey = $progressKey
        }
        Start-Sleep -Milliseconds 120
    }
    try { [void]$ps.EndInvoke($async) }
    finally { $ps.Dispose() }

    $s = Read-ProgressState
    Draw-Progress -Percent ([int]$s.Percent) -Stage ([string]$s.Stage)
    [Console]::WriteLine()

    $status = ''
    $message = ''
    try {
        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($resultFile, $enc950)) {
                if ($line -match '^STATUS=(.*)$') { $status = $matches[1] }
                elseif ($line -match '^MESSAGE=(.*)$') { $message = $matches[1] }
            }
        }
    } catch {}
    if ($status -ne 'OK' -and $status -ne 'MULTIPLE') {
        Write-DetectionDiagnostic -Reason $message -Target $target
    } else {
        Remove-Item -LiteralPath $diagnosticFile -Force -ErrorAction SilentlyContinue
    }
    exit 0
}
catch {
    Write-DetectionDiagnostic -Reason $_.Exception.Message -Target ([string]$env:AVATARSTAR_USER_TARGET)
    try {
        [System.IO.File]::WriteAllLines($resultFile, @('STATUS=ERROR', ('MESSAGE=' + ($_.Exception.Message -replace "`r|`n", ' '))), $enc950)
    } catch {}
    [Console]::WriteLine()
    exit 1
}
