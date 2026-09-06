param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Locate','Inspect','SelectCandidate','Apply991','Restore','Recover','Convert','VisualMatch','Diagnostic')]
    [string]$Action,

    [string]$Target = '',
    [string]$OutFile = '',
    [string]$ConvertMode = '',
    [string]$Value = '',
    [string]$Zoom = '',
    [string]$ProgressFile = '',
    [string]$SessionDir = '',
    [string]$HeartbeatFile = '',
    [string]$OriginalLocalAppData = '',
    [string]$OriginalAppData = '',
    [string]$OriginalUserProfile = '',
    [string]$OriginalUserSid = '',
    [int]$FrontendPid = 0,
    [Int64]$FrontendStartTicks = 0,
    [string]$RequestId = '',
    [string]$ToolVersion = '1.0'
)

$ErrorActionPreference = 'Stop'

# These are known samples only. They are NOT compatibility gates.
$KnownSampleSize = [Int64]1320427520
$KnownOriginalHash = '41157d3b602209f26ab44580792f3cb0b2149b4324493532b61cd0c5038f30fb'
$Known991Hash = '813a0a45cdf0e87572a2d59a5d975f7269940d6630a902820ad13351606ab694'
$KnownOffset1 = [Int64]0x498E3A4F
$KnownOffset2 = [Int64]0x498E3B68
$PatchDelta = [int]0x119
$PatchSpan = $PatchDelta + 8
$ScanOverlap = $PatchSpan - 1

$Original1 = [byte[]](0xA3,0x2D,0x51,0xD7,0xEE,0x68,0xDD,0xA8)
$Original2 = [byte[]](0x3D,0x09,0x84,0xA9,0x86,0x5E,0x6A,0xB9)
$Mode9911 = [byte[]](0xA3,0x2D,0x51,0xD7,0xEE,0x90,0x0A,0xA8)
$Mode9912 = [byte[]](0x3D,0x09,0x84,0xA9,0x86,0xA6,0xBD,0xB9)

$Encoding950 = [System.Text.Encoding]::GetEncoding(950)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$CandidateFile = if ($SessionDir) { Join-Path $SessionDir 'candidates.json' } else { '' }
$CurrentFile = if ($SessionDir) { Join-Path $SessionDir 'current.json' } else { '' }
$DiscoveryTraceFile = if ($SessionDir) { Join-Path $SessionDir 'discovery-last-candidate.txt' } else { '' }
$PersistentSelectionDir = if ($OriginalLocalAppData) { Join-Path $OriginalLocalAppData 'AvatarStarSensitivityTool' } else { '' }
$PersistentSelectionFile = if ($PersistentSelectionDir) { Join-Path $PersistentSelectionDir 'last-selection.json' } else { '' }
$CancelFile = if ($SessionDir -and $RequestId) { Join-Path $SessionDir ('cancel.' + $RequestId + '.flag') } else { '' }
$BlockedFile = if ($SessionDir) { Join-Path $SessionDir 'blocked.flag' } else { '' }
$ClearStateOnError = $false

if (-not ('AvatarStarSensitivity.PairScanner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

namespace AvatarStarSensitivity {
    public sealed class PairMatch {
        public long Offset1;
        public long Offset2;
        public int State;
        public PairMatch(long o1, long o2, int state) { Offset1 = o1; Offset2 = o2; State = state; }
    }

    public static class PairScanner {
        private static bool Match(byte[] data, int length, int index, byte[] pattern) {
            if (index < 0 || pattern == null || index + pattern.Length > length) return false;
            for (int i = 0; i < pattern.Length; i++) {
                if (data[index + i] != pattern[i]) return false;
            }
            return true;
        }

        // State: 1=Original, 2=Mode991, 3=Mixed(O/M), 4=Mixed(M/O)
        public static PairMatch[] FindPairs(
            byte[] data, int length, long absoluteStart, int delta,
            byte[] original1, byte[] mode9911, byte[] original2, byte[] mode9912) {
            var results = new List<PairMatch>();
            int span = delta + 8;
            if (data == null || length < span) return results.ToArray();
            byte first = original1[0];
            int max = length - span;
            int searchFrom = 0;
            while (searchFrom <= max) {
                int hit = Array.IndexOf<byte>(data, first, searchFrom, max - searchFrom + 1);
                if (hit < 0) break;
                bool o1 = Match(data, length, hit, original1);
                bool m1 = !o1 && Match(data, length, hit, mode9911);
                if (o1 || m1) {
                    int j = hit + delta;
                    bool o2 = Match(data, length, j, original2);
                    bool m2 = !o2 && Match(data, length, j, mode9912);
                    if (o2 || m2) {
                        int state = o1 ? (o2 ? 1 : 3) : (m2 ? 2 : 4);
                        results.Add(new PairMatch(absoluteStart + hit, absoluteStart + j, state));
                    }
                }
                searchFrom = hit + 1;
            }
            return results.ToArray();
        }
    }
}
'@
}

function Assert-FrontendAlive {
    if ($FrontendPid -le 0 -or $FrontendStartTicks -le 0) { return }
    try {
        $p = Get-Process -Id $FrontendPid -ErrorAction Stop
        if ($p.StartTime.ToUniversalTime().Ticks -ne $FrontendStartTicks) {
            throw '可見 CMD 工作階段已結束。'
        }
    }
    catch {
        throw '可見 CMD 工作階段已結束。'
    }
}

function Assert-NotCancelled {
    Assert-FrontendAlive
    if (-not [string]::IsNullOrWhiteSpace($BlockedFile) -and (Test-Path -LiteralPath $BlockedFile -PathType Leaf)) {
        throw '目前工作階段已鎖定；請重新啟動工具。'
    }
    if (-not [string]::IsNullOrWhiteSpace($CancelFile) -and (Test-Path -LiteralPath $CancelFile -PathType Leaf)) {
        throw '使用者取消或等待逾時。'
    }
}

function Touch-Heartbeat {
    if ([string]::IsNullOrWhiteSpace($HeartbeatFile)) { return }
    try {
        [System.IO.File]::WriteAllText(
            $HeartbeatFile,
            [DateTime]::UtcNow.Ticks.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            [System.Text.Encoding]::ASCII
        )
    } catch {}
}

function Write-Result {
    param([System.Collections.IDictionary]$Data)
    if ([string]::IsNullOrWhiteSpace($OutFile)) { return }
    # If the frontend already declared this request uncertain and locked the session, do not overwrite its timeout result.
    if (-not [string]::IsNullOrWhiteSpace($BlockedFile) -and (Test-Path -LiteralPath $BlockedFile -PathType Leaf)) { return }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        $lines.Add(('REQUESTID=' + $RequestId))
    }
    foreach ($key in $Data.Keys) {
        $valueText = [string]$Data[$key]
        $valueText = $valueText -replace "`r|`n", ' '
        $lines.Add(('{0}={1}' -f $key, $valueText))
    }
    [System.IO.File]::WriteAllLines($OutFile, $lines, $Encoding950)
}

function Set-ProgressState {
    param([int]$Percent, [string]$Stage)
    Touch-Heartbeat
    if ([string]::IsNullOrWhiteSpace($ProgressFile)) { return }
    try {
        if ($Percent -lt 0) { $Percent = 0 }
        if ($Percent -gt 100) { $Percent = 100 }
        $safeStage = ([string]$Stage) -replace "`r|`n", ' '
        $tmp = $ProgressFile + '.tmp'
        [System.IO.File]::WriteAllLines(
            $tmp,
            @(('PERCENT=' + $Percent), ('STAGE=' + $safeStage)),
            $Encoding950
        )
        Move-Item -LiteralPath $tmp -Destination $ProgressFile -Force
    } catch {}
}

function Bytes-Equal([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) { return $false }
    }
    return $true
}

function Bytes-ToHex([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return '' }
    return ([BitConverter]::ToString($Bytes)).Replace('-', ' ')
}

function Hex-ToBytes([string]$Hex) {
    if ([string]::IsNullOrWhiteSpace($Hex)) { return [byte[]]@() }
    $clean = ($Hex -replace '[^0-9A-Fa-f]', '')
    if (($clean.Length % 2) -ne 0) { throw '交易紀錄中的位元組格式無效。' }
    $bytes = New-Object byte[] ($clean.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16)
    }
    return $bytes
}

function Read-AtStream([System.IO.FileStream]$Stream, [Int64]$Offset, [int]$Count) {
    if ($Offset -lt 0 -or $Offset + $Count -gt $Stream.Length) { throw 'PDE patch offset 超出檔案範圍。' }
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $Count
    $done = 0
    while ($done -lt $Count) {
        $r = $Stream.Read($buf, $done, $Count - $done)
        if ($r -le 0) { throw '讀取 PDE 時遇到非預期檔案結尾。' }
        $done += $r
    }
    return $buf
}

function Write-AtStream([System.IO.FileStream]$Stream, [Int64]$Offset, [byte[]]$Bytes) {
    if ($Offset -lt 0 -or $Offset + $Bytes.Length -gt $Stream.Length) { throw 'PDE patch offset 超出檔案範圍。' }
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function Apply-ReplacementToChunk {
    param(
        [byte[]]$Buffer,
        [int]$Count,
        [Int64]$ChunkStart,
        [Int64]$Offset,
        [byte[]]$Bytes
    )
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return }
    $chunkEnd = $ChunkStart + $Count
    $replaceEnd = $Offset + $Bytes.Length
    $overlapStart = [Math]::Max($ChunkStart, $Offset)
    $overlapEnd = [Math]::Min($chunkEnd, $replaceEnd)
    if ($overlapStart -ge $overlapEnd) { return }
    for ($absolute = $overlapStart; $absolute -lt $overlapEnd; $absolute++) {
        $Buffer[[int]($absolute - $ChunkStart)] = $Bytes[[int]($absolute - $Offset)]
    }
}

function Analyze-Stream {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileStream]$Stream,
        [int]$StartPercent = 0,
        [int]$EndPercent = 100,
        [string]$Stage = '分析 PDE',
        [Int64]$ReplaceOffset1 = -1,
        [byte[]]$ReplaceBytes1 = $null,
        [Int64]$ReplaceOffset2 = -1,
        [byte[]]$ReplaceBytes2 = $null,
        [switch]$IgnoreCancellation
    )

    [void]$Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $shaRebuilt = $null
    $doRebuilt = ($ReplaceOffset1 -ge 0 -and $null -ne $ReplaceBytes1 -and $ReplaceOffset2 -ge 0 -and $null -ne $ReplaceBytes2)
    if ($doRebuilt) { $shaRebuilt = [System.Security.Cryptography.SHA256]::Create() }

    $matches = @{}
    $buffer = New-Object byte[] 8388608
    $carry = New-Object byte[] 0
    $total = [Int64]$Stream.Length
    $done = [Int64]0
    $lastUpdate = [DateTime]::UtcNow.AddSeconds(-1)

    try {
        if ($total -eq 0) {
            [void]$sha.TransformFinalBlock($buffer, 0, 0)
            if ($doRebuilt) { [void]$shaRebuilt.TransformFinalBlock($buffer, 0, 0) }
        }
        else {
            while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if (-not $IgnoreCancellation) { Assert-NotCancelled }
                $chunkStart = $done
                $isLast = (($done + $read) -ge $total)

                if ($isLast) { [void]$sha.TransformFinalBlock($buffer, 0, $read) }
                else { [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0) }

                if ($doRebuilt) {
                    $rebuilt = New-Object byte[] $read
                    [Array]::Copy($buffer, 0, $rebuilt, 0, $read)
                    Apply-ReplacementToChunk -Buffer $rebuilt -Count $read -ChunkStart $chunkStart -Offset $ReplaceOffset1 -Bytes $ReplaceBytes1
                    Apply-ReplacementToChunk -Buffer $rebuilt -Count $read -ChunkStart $chunkStart -Offset $ReplaceOffset2 -Bytes $ReplaceBytes2
                    if ($isLast) { [void]$shaRebuilt.TransformFinalBlock($rebuilt, 0, $read) }
                    else { [void]$shaRebuilt.TransformBlock($rebuilt, 0, $read, $rebuilt, 0) }
                }

                $combinedLength = $carry.Length + $read
                $combined = New-Object byte[] $combinedLength
                if ($carry.Length -gt 0) { [Array]::Copy($carry, 0, $combined, 0, $carry.Length) }
                [Array]::Copy($buffer, 0, $combined, $carry.Length, $read)
                $absoluteStart = $chunkStart - $carry.Length

                $found = [AvatarStarSensitivity.PairScanner]::FindPairs(
                    $combined, $combinedLength, $absoluteStart, $PatchDelta,
                    $Original1, $Mode9911, $Original2, $Mode9912
                )
                foreach ($m in $found) {
                    $key = ([string]$m.Offset1)
                    if (-not $matches.ContainsKey($key)) {
                        $matches[$key] = [PSCustomObject]@{
                            Offset1 = [Int64]$m.Offset1
                            Offset2 = [Int64]$m.Offset2
                            StateCode = [int]$m.State
                        }
                    }
                }

                $keep = [Math]::Min($ScanOverlap, $combinedLength)
                $newCarry = New-Object byte[] $keep
                if ($keep -gt 0) { [Array]::Copy($combined, $combinedLength - $keep, $newCarry, 0, $keep) }
                $carry = $newCarry

                $done += $read
                if (([DateTime]::UtcNow - $lastUpdate).TotalMilliseconds -ge 250) {
                    $ratio = if ($total -gt 0) { $done / [double]$total } else { 1.0 }
                    $pct = $StartPercent + [Math]::Floor(($EndPercent - $StartPercent) * $ratio)
                    Set-ProgressState $pct $Stage
                    $lastUpdate = [DateTime]::UtcNow
                }
            }
        }

        Set-ProgressState $EndPercent $Stage
        $rawHash = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        $rebuiltHash = ''
        if ($doRebuilt) { $rebuiltHash = ([BitConverter]::ToString($shaRebuilt.Hash)).Replace('-', '').ToLowerInvariant() }
        $matchList = @($matches.Values | Sort-Object Offset1)

        return [PSCustomObject]@{
            Size = $total
            Hash = $rawHash
            RebuiltHash = $rebuiltHash
            Matches = $matchList
            MatchCount = $matchList.Count
        }
    }
    finally {
        $sha.Dispose()
        if ($null -ne $shaRebuilt) { $shaRebuilt.Dispose() }
    }
}

function Get-StateNameFromCode([int]$Code) {
    switch ($Code) {
        1 { return 'Original' }
        2 { return 'Mode991' }
        3 { return 'Mixed' }
        4 { return 'Mixed' }
        default { return 'Unknown' }
    }
}

function Get-StateLabel([string]$State) {
    switch ($State) {
        'Original' { return '官方原版' }
        'Mode991' { return '1~991' }
        'Mixed' { return '不完整修改' }
        'Ambiguous' { return '找到多組候選' }
        'Unstable' { return '檔案分析中發生變化' }
        default { return '未知' }
    }
}

function Get-KnownSampleLabel([string]$Hash) {
    if ($Hash -eq $KnownOriginalHash) { return '官方已知樣本' }
    if ($Hash -eq $Known991Hash) { return '1~991 已知樣本' }
    return '其他安裝樣本'
}

function Get-TransactionPath([string]$Pde) {
    return ($Pde + '.ast-sens.txn.json')
}

function Read-Transaction([string]$Pde) {
    $path = Get-TransactionPath $Pde
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, $Utf8NoBom)
        $j = $raw | ConvertFrom-Json
        $names = @($j.PSObject.Properties.Name)
        foreach ($required in @('PreHash','PreSize','Offset1','Offset2','Before1','Before2','Target1','Target2','TargetState')) {
            if ($names -notcontains $required) { throw ('交易紀錄缺少欄位：' + $required) }
        }
        if ([string]::IsNullOrWhiteSpace([string]$j.PreHash) -or
            [string]::IsNullOrWhiteSpace([string]$j.Before1) -or
            [string]::IsNullOrWhiteSpace([string]$j.Before2) -or
            [string]::IsNullOrWhiteSpace([string]$j.Target1) -or
            [string]::IsNullOrWhiteSpace([string]$j.Target2) -or
            [string]::IsNullOrWhiteSpace([string]$j.TargetState)) {
            throw '交易紀錄欄位內容不完整。'
        }
        return $j
    }
    catch {
        return [PSCustomObject]@{ Invalid = $true; Error = $_.Exception.Message; Path = $path }
    }
}

function Write-Transaction {
    param(
        [string]$Pde,
        [string]$PreHash,
        [Int64]$PreSize,
        [Int64]$Offset1,
        [Int64]$Offset2,
        [byte[]]$Before1,
        [byte[]]$Before2,
        [byte[]]$Target1,
        [byte[]]$Target2,
        [string]$TargetState
    )
    $path = Get-TransactionPath $Pde
    $tmp = $path + '.tmp'
    $payload = [ordered]@{
        ToolVersion = $ToolVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        PreHash = $PreHash
        PreSize = $PreSize
        Offset1 = $Offset1
        Offset2 = $Offset2
        Before1 = Bytes-ToHex $Before1
        Before2 = Bytes-ToHex $Before2
        Target1 = Bytes-ToHex $Target1
        Target2 = Bytes-ToHex $Target2
        TargetState = $TargetState
    }
    $json = $payload | ConvertTo-Json -Compress
    $bytes = $Utf8NoBom.GetBytes($json)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $jf = $null
    try {
        $jf = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $jf.Write($bytes, 0, $bytes.Length)
        $jf.Flush($true)
        $jf.Dispose(); $jf = $null
        Move-Item -LiteralPath $tmp -Destination $path -Force
        return $path
    }
    catch {
        if ($null -ne $jf) { $jf.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Remove-Transaction([string]$Pde) {
    $path = Get-TransactionPath $Pde
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($path + '.tmp') -Force -ErrorAction SilentlyContinue
}


function Evaluate-TransactionState {
    param(
        [string]$Pde,
        $Journal,
        $Analysis
    )
    # Inspection is intentionally read-only. Any transaction journal means the
    # previous write lifecycle did not reach its final cleanup point. Do not
    # delete or mutate the journal from a read-only inspection path; explicit
    # recovery will obtain an exclusive PDE handle and decide whether the
    # transaction was never written, fully committed, or partially written.
    if ($null -eq $Journal) {
        return [PSCustomObject]@{ Recovery='NO'; Message=''; Journal=$null }
    }
    if ($Journal.PSObject.Properties.Name -contains 'Invalid' -and $Journal.Invalid) {
        return [PSCustomObject]@{
            Recovery='YES'
            Message=('交易紀錄無法解析：' + [string]$Journal.Error)
            Journal=$Journal
        }
    }
    return [PSCustomObject]@{
        Recovery='YES'
        Message='偵測到未完成清理的修改交易；請先執行安全復原 / 交易確認。'
        Journal=$Journal
    }
}

function Normalize-FolderPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [string]::IsNullOrWhiteSpace($root) -and $full.TrimEnd('\') -ieq $root.TrimEnd('\')) {
        return $root
    }
    return $full.TrimEnd('\')
}

function Resolve-PdeCandidate([string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $null }
    $p = $InputPath.Trim().Trim('"')
    try {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            if ([System.IO.Path]::GetFileName($p) -ieq 'AvatarStar.pde') {
                $folder = Split-Path -LiteralPath $p -Parent
                return [PSCustomObject]@{ Folder=(Normalize-FolderPath $folder); Pde=[System.IO.Path]::GetFullPath($p) }
            }
            $p = Split-Path -LiteralPath $p -Parent
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $null }

        $cur = Normalize-FolderPath $p
        for ($level = 0; $level -le 5; $level++) {
            $pde = Join-Path $cur 'AvatarStar.pde'
            if ([System.IO.File]::Exists($pde)) {
                return [PSCustomObject]@{ Folder=$cur; Pde=$pde }
            }
            $parent = [System.IO.Directory]::GetParent($cur)
            if ($null -eq $parent) { break }
            $next = Normalize-FolderPath $parent.FullName
            if ($next -eq $cur) { break }
            $cur = $next
        }
    } catch {}
    return $null
}


function Resolve-ManualPdeCandidate([string]$InputPath) {
    $direct = Resolve-PdeCandidate $InputPath
    if ($null -ne $direct) { return $direct }

    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $null }
    $p = $InputPath.Trim().Trim('"')
    try {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $p = Split-Path -LiteralPath $p -Parent
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $null }

        $root = Normalize-FolderPath $p
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue([PSCustomObject]@{ Path=$root; Depth=0 })
        $found = New-Object System.Collections.ArrayList
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while ($queue.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt 12) {
            Assert-NotCancelled
            $item = $queue.Dequeue()
            try {
                $pde = Join-Path ([string]$item.Path) 'AvatarStar.pde'
                if ([System.IO.File]::Exists($pde)) {
                    [void]$found.Add($pde)
                    if ($found.Count -gt 1) { break }
                }
            } catch {}

            if ([int]$item.Depth -ge 3) { continue }
            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories([string]$item.Path)) {
                    try {
                        $childPde = Join-Path $sub 'AvatarStar.pde'
                        if ([System.IO.File]::Exists($childPde)) {
                            $resolved = Resolve-PdeCandidate $childPde
                            if ($null -ne $resolved) {
                                $duplicate = $false
                                foreach ($x in $found) { if ([string]$x.Folder -ieq [string]$resolved.Folder) { $duplicate = $true; break } }
                                if (-not $duplicate) { [void]$found.Add($resolved) }
                            }
                        }
                        $attr = [System.IO.File]::GetAttributes($sub)
                        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $queue.Enqueue([PSCustomObject]@{ Path=$sub; Depth=([int]$item.Depth + 1) })
                    } catch {}
                }
            } catch {}
            Touch-Heartbeat
        }
        $sw.Stop()

        if ($found.Count -eq 1) { return Resolve-PdeCandidate ([string]$found[0]) }
        if ($found.Count -gt 1) {
            throw '指定的上層資料夾內找到多份 AvatarStar.pde；請直接指定目前遊戲的 AvatarStar.pde 或 client.exe。'
        }
    }
    catch {
        if ($_.Exception.Message -like '指定的上層資料夾內找到多份*') { throw }
    }
    return $null
}

function Replace-LiteralIgnoreCase([string]$Text, [string]$Token, [string]$Replacement) {
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Token)) { return $Text }
    $result = $Text
    $start = 0
    while ($true) {
        $idx = $result.IndexOf($Token, $start, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { break }
        $result = $result.Substring(0, $idx) + $Replacement + $result.Substring($idx + $Token.Length)
        $start = $idx + $Replacement.Length
    }
    return $result
}

function Expand-OriginalUserVariables([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $s = $Value
    $map = @{
        '%LOCALAPPDATA%' = $OriginalLocalAppData
        '%APPDATA%' = $OriginalAppData
        '%USERPROFILE%' = $OriginalUserProfile
    }
    foreach ($k in $map.Keys) {
        $v = [string]$map[$k]
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            $s = Replace-LiteralIgnoreCase $s $k $v
        }
    }
    return [Environment]::ExpandEnvironmentVariables($s)
}

function Find-ExecutableCandidates([string]$Folder) {
    $found = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    foreach ($name in @('client.exe','AvatarStar.exe')) {
        $direct = Join-Path $Folder $name
        if (Test-Path -LiteralPath $direct -PathType Leaf) { [void]$found.Add($direct) }
    }
    if ($found.Count -gt 0) { return @($found | Select-Object -Unique) }

    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([PSCustomObject]@{ Path=$Folder; Depth=0 })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($item.Depth -ge 2) { continue }
        try {
            foreach ($sub in [System.IO.Directory]::GetDirectories([string]$item.Path)) {
                try {
                    $attr = [System.IO.File]::GetAttributes($sub)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    foreach ($name in @('client.exe','AvatarStar.exe')) {
                        $exe = Join-Path $sub $name
                        if (Test-Path -LiteralPath $exe -PathType Leaf) { [void]$found.Add($exe) }
                    }
                    $queue.Enqueue([PSCustomObject]@{ Path=$sub; Depth=([int]$item.Depth + 1) })
                } catch {}
            }
        } catch {}
        if ($found.Count -gt 0) { break }
    }
    return @($found | Select-Object -Unique)
}

function Get-GameVersion {
    param([string]$Folder, [string]$PreferredExe = '')
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($PreferredExe)) {
        try {
            $leaf = [System.IO.Path]::GetFileName($PreferredExe)
            if ($leaf -ieq 'client.exe' -or $leaf -ieq 'AvatarStar.exe') { [void]$candidates.Add($PreferredExe) }
        } catch {}
    }
    foreach ($exe in (Find-ExecutableCandidates $Folder)) { [void]$candidates.Add($exe) }
    foreach ($exe in ($candidates | Select-Object -Unique)) {
        try {
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
            $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
            if (-not [string]::IsNullOrWhiteSpace([string]$version)) { return ([string]$version).Trim() }
        } catch {}
    }
    return '無法讀取'
}

function Save-PersistentSelection($Candidate) {
    if ([string]::IsNullOrWhiteSpace($PersistentSelectionFile)) { return }
    try {
        if (-not (Test-Path -LiteralPath $PersistentSelectionDir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($PersistentSelectionDir)
        }
        $payload = [ordered]@{
            Folder = [string]$Candidate.Folder
            Pde = [string]$Candidate.Pde
            PreferredExe = [string]$Candidate.PreferredExe
            SavedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $tmp = $PersistentSelectionFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Compress), $Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $PersistentSelectionFile -Force
    }
    catch {
        try { Remove-Item -LiteralPath ($PersistentSelectionFile + '.tmp') -Force -ErrorAction SilentlyContinue } catch {}
        # Persistence is only a discovery optimization. Do not fail a valid
        # current session merely because LocalAppData cannot be written.
    }
}

function Resolve-SavedPdeExact([string]$SavedPde) {
    if ([string]::IsNullOrWhiteSpace($SavedPde)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($SavedPde.Trim().Trim('"'))
        if ([System.IO.Path]::GetFileName($full) -ine 'AvatarStar.pde') { return $null }
        # Saved selections already contain the exact PDE path discovered and
        # inspected earlier. Do not feed that exact file back through the
        # broader candidate resolver: on some Windows/PowerShell 5.1 systems
        # that provider-based re-resolution can return null even though the
        # same File.Exists lookup used by discovery just succeeded.
        if (-not [System.IO.File]::Exists($full)) { return $null }
        $folder = [System.IO.Path]::GetDirectoryName($full)
        if ([string]::IsNullOrWhiteSpace($folder)) { return $null }
        return [PSCustomObject]@{ Folder=(Normalize-FolderPath $folder); Pde=$full }
    }
    catch { return $null }
}

function Read-PersistentSelection {
    if ([string]::IsNullOrWhiteSpace($PersistentSelectionFile) -or -not (Test-Path -LiteralPath $PersistentSelectionFile -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($PersistentSelectionFile, $Utf8NoBom)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
        $saved = $raw | ConvertFrom-Json
        $pde = [string]$saved.Pde
        if ([string]::IsNullOrWhiteSpace($pde)) { throw 'missing path' }
        $resolved = Resolve-SavedPdeExact $pde
        if ($null -eq $resolved) { throw 'stale path' }
        return [PSCustomObject]@{
            Folder=$resolved.Folder
            Pde=$resolved.Pde
            Source='上次成功位置'
            PreferredExe=[string]$saved.PreferredExe
        }
    }
    catch {
        try { Remove-Item -LiteralPath $PersistentSelectionFile -Force -ErrorAction SilentlyContinue } catch {}
        return $null
    }
}

function Find-PersistentCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 8 '檢查上次成功的遊戲位置'
    $saved = Read-PersistentSelection
    if ($null -ne $saved) { [void]$list.Add($saved) }
    return $list
}

function Save-CurrentSelection($Candidate) {
    if ([string]::IsNullOrWhiteSpace($CurrentFile)) { throw '目前工作階段無法保存遊戲選擇。' }
    $payload = [ordered]@{
        Folder = [string]$Candidate.Folder
        Pde = [string]$Candidate.Pde
        Source = [string]$Candidate.Source
        PreferredExe = [string]$Candidate.PreferredExe
    }
    $tmp = $CurrentFile + '.tmp'
    try {
        [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Compress), $Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $CurrentFile -Force
        # Verify the exact persisted selection before reporting detection success.
        $saved = Read-CurrentSelection
        if ($null -eq $saved -or ([string]$saved.Pde -ine [string]$Candidate.Pde)) {
            throw '遊戲選擇狀態寫入後驗證失敗。'
        }
        Save-PersistentSelection $Candidate
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Clear-CurrentSelection {
    if (-not [string]::IsNullOrWhiteSpace($CurrentFile)) {
        Remove-Item -LiteralPath $CurrentFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($CurrentFile + '.tmp') -Force -ErrorAction SilentlyContinue
    }
}

function Read-CurrentSelection {
    if ([string]::IsNullOrWhiteSpace($CurrentFile) -or -not (Test-Path -LiteralPath $CurrentFile -PathType Leaf)) {
        throw '目前沒有已選定的遊戲安裝，請重新偵測。'
    }
    $raw = [System.IO.File]::ReadAllText($CurrentFile, $Utf8NoBom)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw '目前遊戲選擇狀態已損壞，請重新偵測。' }
    $c = $raw | ConvertFrom-Json
    $savedPde = [string]$c.Pde
    if ([string]::IsNullOrWhiteSpace($savedPde)) { throw '目前遊戲選擇狀態缺少 PDE 路徑，請重新偵測。' }
    $resolved = Resolve-SavedPdeExact $savedPde
    if ($null -eq $resolved) { throw '先前選定的 AvatarStar.pde 已不存在，請重新偵測。' }
    return [PSCustomObject]@{
        Folder=$resolved.Folder; Pde=$resolved.Pde; Source=[string]$c.Source; PreferredExe=[string]$c.PreferredExe
    }
}

function Resolve-ActionCandidate {
    # Stateful actions use only the elevated worker session's UTF-8 persisted
    # selection. The PDE path is never round-tripped through CMD/result/env IPC.
    try {
        return Read-CurrentSelection
    }
    catch {
        $script:ClearStateOnError = $true
        throw
    }
}

function Inspect-Candidate {
    param(
        [Parameter(Mandatory=$true)]$Candidate,
        [int]$StartPercent = 10,
        [int]$EndPercent = 98
    )
    Assert-NotCancelled
    $pde = [string]$Candidate.Pde
    if (-not (Test-Path -LiteralPath $pde -PathType Leaf)) {
        return [PSCustomObject]@{
            Status='NOTFOUND'; Folder=''; Pde=''; PdeStatus='NOTFOUND'; Size=0; Hash='';
            State='Unknown'; Label='未知'; Compat='UNVERIFIED'; GameVersion='無法讀取'; Source='';
            MatchCount=0; Offset1=''; Offset2=''; Bytes1=''; Bytes2=''; KnownSample='';
            Recovery='NO'; RecoveryMessage=''; AnalysisMethod='Dynamic paired signature'; Stable='NO';
            AnalysisError='AvatarStar.pde 不存在。'
        }
    }

    $journal = Read-Transaction $pde
    $gameVersion = Get-GameVersion ([string]$Candidate.Folder) ([string]$Candidate.PreferredExe)

    try {
        $before = Get-Item -LiteralPath $pde
        $beforeLength = [Int64]$before.Length
        $beforeWrite = $before.LastWriteTimeUtc.Ticks
        Set-ProgressState $StartPercent '分析 AvatarStar.pde'

        $fs = [System.IO.File]::Open(
            $pde,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $analysis = Analyze-Stream -Stream $fs -StartPercent $StartPercent -EndPercent ($EndPercent - 4) -Stage '分析 PDE / SHA-256 / 靈敏度結構'
        }
        finally {
            $fs.Dispose()
        }

        if (-not (Test-Path -LiteralPath $pde -PathType Leaf)) {
            return [PSCustomObject]@{
                Status='NOTFOUND'; Folder=''; Pde=''; PdeStatus='NOTFOUND'; Size=0; Hash='';
                State='Unknown'; Label='未知'; Compat='UNVERIFIED'; GameVersion=$gameVersion; Source=[string]$Candidate.Source;
                MatchCount=0; Offset1=''; Offset2=''; Bytes1=''; Bytes2=''; KnownSample='';
                Recovery='NO'; RecoveryMessage=''; AnalysisMethod='Dynamic paired signature'; Stable='NO';
                AnalysisError='AvatarStar.pde 在分析期間已不存在。'
            }
        }

        $after = Get-Item -LiteralPath $pde
        $stable = (([Int64]$after.Length -eq $beforeLength) -and ($after.LastWriteTimeUtc.Ticks -eq $beforeWrite))

        $state = 'Unknown'
        $offset1 = ''
        $offset2 = ''
        $bytes1 = ''
        $bytes2 = ''
        if (-not $stable) {
            $state = 'Unstable'
        }
        elseif ($analysis.MatchCount -eq 1) {
            $m = $analysis.Matches[0]
            $state = Get-StateNameFromCode ([int]$m.StateCode)
            $offset1 = ('0x{0:X}' -f [Int64]$m.Offset1)
            $offset2 = ('0x{0:X}' -f [Int64]$m.Offset2)
            switch ([int]$m.StateCode) {
                1 { $bytes1 = Bytes-ToHex $Original1; $bytes2 = Bytes-ToHex $Original2 }
                2 { $bytes1 = Bytes-ToHex $Mode9911; $bytes2 = Bytes-ToHex $Mode9912 }
                3 { $bytes1 = Bytes-ToHex $Original1; $bytes2 = Bytes-ToHex $Mode9912 }
                4 { $bytes1 = Bytes-ToHex $Mode9911; $bytes2 = Bytes-ToHex $Original2 }
            }
        }
        elseif ($analysis.MatchCount -gt 1) {
            $state = 'Ambiguous'
        }

        $tx = Evaluate-TransactionState -Pde $pde -Journal $journal -Analysis $analysis
        $compat = 'UNVERIFIED'
        if ($stable -and $tx.Recovery -eq 'NO' -and $analysis.MatchCount -eq 1 -and ($state -eq 'Original' -or $state -eq 'Mode991')) {
            $compat = 'SUPPORTED'
        }
        elseif ($tx.Recovery -eq 'YES') {
            $compat = 'RECOVERY'
        }

        Set-ProgressState $EndPercent 'PDE 分析完成'
        return [PSCustomObject]@{
            Status='OK'
            Folder=[string]$Candidate.Folder
            Pde=$pde
            PdeStatus='FOUND'
            Size=[Int64]$analysis.Size
            Hash=[string]$analysis.Hash
            State=$state
            Label=(Get-StateLabel $state)
            Compat=$compat
            GameVersion=$gameVersion
            Source=[string]$Candidate.Source
            MatchCount=[int]$analysis.MatchCount
            Offset1=$offset1
            Offset2=$offset2
            Bytes1=$bytes1
            Bytes2=$bytes2
            KnownSample=(Get-KnownSampleLabel ([string]$analysis.Hash))
            Recovery=[string]$tx.Recovery
            RecoveryMessage=[string]$tx.Message
            AnalysisMethod='Dynamic paired signature'
            Stable=$(if ($stable) { 'YES' } else { 'NO' })
            AnalysisError=''
        }
    }
    catch {
        # Path discovery and patch compatibility are intentionally separate.
        # A real AvatarStar.pde remains "found" even when it cannot currently
        # be hashed/read (locked file, transient I/O, permissions, etc.).
        $size = [Int64]0
        try { $size = [Int64](Get-Item -LiteralPath $pde -ErrorAction Stop).Length } catch {}
        $tx = Evaluate-TransactionState -Pde $pde -Journal $journal -Analysis $null
        $compat = if ($tx.Recovery -eq 'YES') { 'RECOVERY' } else { 'UNVERIFIED' }
        Set-ProgressState $EndPercent 'PDE 已找到，但目前無法完成分析'
        return [PSCustomObject]@{
            Status='OK'
            Folder=[string]$Candidate.Folder
            Pde=$pde
            PdeStatus='FOUND'
            Size=$size
            Hash=''
            State='Unknown'
            Label='未知'
            Compat=$compat
            GameVersion=$gameVersion
            Source=[string]$Candidate.Source
            MatchCount=0
            Offset1=''
            Offset2=''
            Bytes1=''
            Bytes2=''
            KnownSample='尚未完成分析'
            Recovery=[string]$tx.Recovery
            RecoveryMessage=[string]$tx.Message
            AnalysisMethod='Dynamic paired signature'
            Stable='NO'
            AnalysisError=$_.Exception.Message
        }
    }
}

function Add-ResolvedCandidate {
    param([System.Collections.ArrayList]$List, $Resolved, [string]$Source, [string]$PreferredExe = '')
    if ($null -eq $Resolved) { return }
    foreach ($existing in $List) {
        if ([string]$existing.Folder -ieq [string]$Resolved.Folder) {
            if ([string]::IsNullOrWhiteSpace([string]$existing.PreferredExe) -and -not [string]::IsNullOrWhiteSpace($PreferredExe)) { $existing.PreferredExe = $PreferredExe }
            return
        }
    }
    [void]$List.Add([PSCustomObject]@{ Folder=$Resolved.Folder; Pde=$Resolved.Pde; Source=$Source; PreferredExe=$PreferredExe })
}

function Find-NearbyPdeCandidates([string]$InputPath, [int]$MaxDepth = 2) {
    $found = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return @() }
    $p = $InputPath.Trim().Trim('"')
    try {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path -LiteralPath $p -Parent }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return @() }
        $root = Normalize-FolderPath $p
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue([PSCustomObject]@{ Path=$root; Depth=0 })
        $visited = 0
        while ($queue.Count -gt 0) {
            Assert-NotCancelled
            $item = $queue.Dequeue()
            $visited++
            try {
                $pde = Join-Path ([string]$item.Path) 'AvatarStar.pde'
                if ([System.IO.File]::Exists($pde)) {
                    $resolved = Resolve-PdeCandidate $pde
                    if ($null -ne $resolved) {
                        $duplicate = $false
                        foreach ($x in $found) { if ([string]$x.Folder -ieq [string]$resolved.Folder) { $duplicate = $true; break } }
                        if (-not $duplicate) { [void]$found.Add($resolved) }
                    }
                }
            } catch {}
            if ([int]$item.Depth -ge $MaxDepth) { continue }
            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories([string]$item.Path)) {
                    try {
                        $attr = [System.IO.File]::GetAttributes($sub)
                        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $queue.Enqueue([PSCustomObject]@{ Path=$sub; Depth=([int]$item.Depth + 1) })
                    } catch {}
                }
            } catch {}
            if (($visited % 25) -eq 0) { Touch-Heartbeat }
        }
    } catch {}
    return @($found)
}

function Add-Candidate {
    param([System.Collections.ArrayList]$List, [string]$Path, [string]$Source, [string]$PreferredExe = '')
    $obj = Resolve-PdeCandidate $Path
    if ($null -ne $obj) {
        Add-ResolvedCandidate $List $obj $Source $PreferredExe
        return
    }

    # Registry entries and shortcuts often point at a launcher/install root while
    # AvatarStar.pde is one or two directories below it. Search only a shallow,
    # bounded neighborhood here; the true all-disk fallback remains a separate tier.
    foreach ($near in @(Find-NearbyPdeCandidates -InputPath $Path -MaxDepth 2)) {
        Add-ResolvedCandidate $List $near $Source $PreferredExe
    }
}

function Find-RunningCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 4 '檢查執行中的 client.exe / AvatarStar.exe'
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and ($_.Name -ieq 'client.exe' -or $_.Name -ieq 'AvatarStar.exe')
        }
        foreach ($proc in $procs) {
            try { Add-Candidate $list ([string]$proc.ExecutablePath) '執行中遊戲' ([string]$proc.ExecutablePath) } catch {}
        }
    } catch {}
    foreach ($name in @('client','AvatarStar')) {
        try {
            foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try { if ($proc.Path) { Add-Candidate $list ([string]$proc.Path) '執行中遊戲' ([string]$proc.Path) } } catch {}
            }
        } catch {}
    }
    return $list
}

function Find-AppDataCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 10 '檢查原始使用者 LOCALAPPDATA'
    $base = $OriginalLocalAppData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { return $list }
    foreach ($relative in @(
        'Programs\AvatarStar','Programs\Avatar Star','AvatarStar','Avatar Star',
        '917play\百變兵團','917Play\百變兵團','917play\AvatarStar','917Play\AvatarStar',
        'Programs\917play\百變兵團','Programs\917play\AvatarStar'
    )) {
        try { Add-Candidate $list (Join-Path $base $relative) '原始使用者 LOCALAPPDATA' '' } catch {}
    }
    return $list
}

function Convert-RegistryValueToCandidate([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $s = Expand-OriginalUserVariables $Raw.Trim()
    if ($s -match '^"([^"]+)"') { return $matches[1] }
    if ($s -match '^(.+?\.exe)(?:\s|,|$)') { return $matches[1] }
    return $s.Trim('"')
}

function Find-RegistryCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 20 '讀取 Windows 安裝紀錄 / Registry'
    $keys = New-Object System.Collections.ArrayList
    [void]$keys.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    [void]$keys.Add('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    if (-not [string]::IsNullOrWhiteSpace($OriginalUserSid)) {
        [void]$keys.Add(('Registry::HKEY_USERS\{0}\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -f $OriginalUserSid))
        [void]$keys.Add(('Registry::HKEY_USERS\{0}\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -f $OriginalUserSid))
    }
    foreach ($key in $keys) {
        Assert-NotCancelled
        try {
            $items = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object {
                ($_.DisplayName -match '百變兵團|Avatar.?Star|917play') -or
                ($_.InstallLocation -match 'AvatarStar|百變兵團|917play') -or
                ($_.DisplayIcon -match 'AvatarStar|百變兵團|917play') -or
                ($_.UninstallString -match 'AvatarStar|百變兵團|917play')
            }
            foreach ($item in $items) {
                foreach ($raw in @($item.InstallLocation, $item.DisplayIcon, $item.UninstallString, $item.InstallSource)) {
                    $candidate = Convert-RegistryValueToCandidate ([string]$raw)
                    if ($candidate) { Add-Candidate $list $candidate 'Windows 安裝紀錄 / Registry' '' }
                }
            }
        } catch {}
        Touch-Heartbeat
    }
    return $list
}

function Get-OriginalUserShellFolder([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($OriginalUserSid)) { return '' }
    try {
        $key = ('Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -f $OriginalUserSid)
        $raw = (Get-ItemProperty -LiteralPath $key -Name $Name -ErrorAction Stop).$Name
        return (Expand-OriginalUserVariables ([string]$raw))
    } catch { return '' }
}


function Find-ShortcutCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 30 '檢查桌面與開始選單捷徑'
    $roots = New-Object System.Collections.ArrayList
    foreach ($p in @(
        (Get-OriginalUserShellFolder 'Desktop'),
        (Get-OriginalUserShellFolder 'Start Menu'),
        $(if ($OriginalUserProfile) { Join-Path $OriginalUserProfile 'Desktop' } else { '' }),
        $(if ($OriginalAppData) { Join-Path $OriginalAppData 'Microsoft\Windows\Start Menu' } else { '' }),
        $(if ($env:PUBLIC) { Join-Path $env:PUBLIC 'Desktop' } else { '' }),
        $(if ($env:ProgramData) { Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu' } else { '' })
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [void]$roots.Add([string]$p) }
    }

    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($root in ($roots | Select-Object -Unique)) {
            Assert-NotCancelled
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

            $stack = New-Object 'System.Collections.Generic.Stack[object]'
            $stack.Push([PSCustomObject]@{ Path=[string]$root; Depth=0 })
            $visited = 0
            while ($stack.Count -gt 0) {
                Assert-NotCancelled
                $item = $stack.Pop()
                $visited++

                try {
                    foreach ($lnk in [System.IO.Directory]::EnumerateFiles([string]$item.Path, '*.lnk', [System.IO.SearchOption]::TopDirectoryOnly)) {
                        try {
                            $shortcut = $ws.CreateShortcut($lnk)
                            foreach ($candidatePath in @($shortcut.TargetPath, $shortcut.WorkingDirectory)) {
                                if ($candidatePath) {
                                    Add-Candidate $list (Expand-OriginalUserVariables ([string]$candidatePath)) '桌面 / 開始選單捷徑' ''
                                }
                            }
                        } catch {}
                    }
                } catch {}

                # Desktop / Start Menu trees are normally shallow. Depth cap prevents
                # redirected or malformed shell folders from becoming an unbounded scan.
                if ([int]$item.Depth -lt 6) {
                    try {
                        foreach ($sub in [System.IO.Directory]::EnumerateDirectories([string]$item.Path)) {
                            try {
                                $attr = [System.IO.File]::GetAttributes($sub)
                                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                                $stack.Push([PSCustomObject]@{ Path=$sub; Depth=([int]$item.Depth + 1) })
                            } catch {}
                        }
                    } catch {}
                }

                if (($visited % 20) -eq 0) {
                    Touch-Heartbeat
                    Set-ProgressState 32 '檢查桌面與開始選單捷徑'
                }
            }
            Touch-Heartbeat
        }
    } catch {}
    return $list
}

function Get-EligibleFileSystemDrives {
    # A local game drive is not guaranteed to report DriveType=Fixed.
    # External SSDs, some virtual disks and vendor drivers can report
    # Removable or Unknown. Exclude only network and optical volumes.
    $roots = New-Object System.Collections.ArrayList
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $drive.IsReady) { continue }
                if ($drive.DriveType -eq [System.IO.DriveType]::Network) { continue }
                if ($drive.DriveType -eq [System.IO.DriveType]::CDRom) { continue }
                $root = [System.IO.Path]::GetFullPath($drive.RootDirectory.FullName)
                $exists = $false
                foreach ($x in $roots) { if ([string]$x.Root -ieq $root) { $exists = $true; break } }
                if (-not $exists) { [void]$roots.Add([PSCustomObject]@{ Root=$root; DriveType=[string]$drive.DriveType }) }
            } catch {}
        }
    } catch {}
    try {
        foreach ($psd in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            try {
                $root = [string]$psd.Root
                if ([string]::IsNullOrWhiteSpace($root)) { continue }
                if ($root.StartsWith('\\')) { continue }
                $root = [System.IO.Path]::GetFullPath($root)
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                $exists = $false
                foreach ($x in $roots) { if ([string]$x.Root -ieq $root) { $exists = $true; break } }
                if (-not $exists) { [void]$roots.Add([PSCustomObject]@{ Root=$root; DriveType='FileSystem' }) }
            } catch {}
        }
    } catch {}
    return @($roots)
}

function Find-CommonCandidates {
    $list = New-Object System.Collections.ArrayList
    Set-ProgressState 40 '檢查各磁碟常見安裝位置'
    try {
        $drives = @(Get-EligibleFileSystemDrives)
        foreach ($drive in $drives) {
            Assert-NotCancelled
            foreach ($relative in @(
                'Program Files (x86)\917play\百變兵團','Program Files\917play\百變兵團',
                'Program Files (x86)\917play\AvatarStar','Program Files\917play\AvatarStar',
                'Program Files (x86)\AvatarStar','Program Files\AvatarStar',
                'Program Files (x86)\Avatar Star','Program Files\Avatar Star',
                '917play\百變兵團','917Play\百變兵團','917play\AvatarStar','917Play\AvatarStar',
                'AvatarStar','Avatar Star','百變兵團',
                'Games\AvatarStar','Game\AvatarStar','Games\百變兵團','Game\百變兵團'
            )) {
                try { Add-Candidate $list (Join-Path $drive.Root $relative) '常見安裝位置' '' } catch {}
            }
        }
    } catch {}
    return $list
}


function Search-RootForPde {
    param([string]$Root, [string]$Source, [int]$MaxSeconds, [int]$StartPercent, [int]$EndPercent)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [PSCustomObject]@{ Candidate=$null; TimedOut=$false }
    }

    # Full-disk fallback uses an iterative stack to avoid BFS queue growth on
    # drives with very large directory trees. Common/shallow locations were
    # already checked by higher-priority tiers.
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push([System.IO.Path]::GetFullPath($Root))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dirs = 0

    while ($stack.Count -gt 0) {
        Assert-NotCancelled
        if ($MaxSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $MaxSeconds) {
            $sw.Stop()
            return [PSCustomObject]@{ Candidate=$null; TimedOut=$true }
        }

        $dir = $stack.Pop()
        $dirs++
        try {
            $pde = Join-Path $dir 'AvatarStar.pde'
            if ([System.IO.File]::Exists($pde)) {
                $obj = Resolve-PdeCandidate $pde
                if ($null -ne $obj) {
                    $sw.Stop()
                    return [PSCustomObject]@{
                        Candidate=[PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source=$Source; PreferredExe='' }
                        TimedOut=$false
                    }
                }
            }
        } catch {}

        if (($dirs % 100) -eq 0) {
            $span = [Math]::Max(1, $EndPercent - $StartPercent)
            $inc = [Math]::Min($span - 1, [Math]::Floor($dirs / 600))
            Set-ProgressState ($StartPercent + $inc) ($Source + '：搜尋 AvatarStar.pde')
        }
        elseif (($dirs % 20) -eq 0) {
            Touch-Heartbeat
        }

        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                Assert-NotCancelled
                if ($MaxSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $MaxSeconds) { break }
                try {
                    $childPde = Join-Path $sub 'AvatarStar.pde'
                    if ([System.IO.File]::Exists($childPde)) {
                        $obj = Resolve-PdeCandidate $childPde
                        if ($null -ne $obj) {
                            $sw.Stop()
                            return [PSCustomObject]@{
                                Candidate=[PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source=$Source; PreferredExe='' }
                                TimedOut=$false
                            }
                        }
                    }
                    $attr = [System.IO.File]::GetAttributes($sub)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push($sub)
                } catch {}
            }
        } catch {}
    }

    $sw.Stop()
    return [PSCustomObject]@{ Candidate=$null; TimedOut=$false }
}

function Find-FullDiskCandidate {
    # Search all fixed drives fairly instead of exhausting C: before D:/E:.
    # Higher-priority known/common locations have already been checked. Each
    # drive gets one directory step per round and we also check immediate child
    # folders before descending, so a large first drive cannot starve others.
    $drives = @(Get-EligibleFileSystemDrives)
    if ($drives.Count -eq 0) { return [PSCustomObject]@{ Candidate=$null; TimedOut=$false } }

    $states = New-Object System.Collections.ArrayList
    foreach ($drive in $drives) {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push([System.IO.Path]::GetFullPath($drive.Root))
        [void]$states.Add([PSCustomObject]@{ Root=[string]$drive.Root; Stack=$stack; Checked=[Int64]0 })
    }

    $totalChecked = [Int64]0
    $lastUpdate = [DateTime]::UtcNow.AddSeconds(-1)
    while ($true) {
        Assert-NotCancelled
        $active = 0
        foreach ($state in $states) {
            if ($state.Stack.Count -eq 0) { continue }
            $active++
            $dir = $state.Stack.Pop()
            $state.Checked = [Int64]$state.Checked + 1
            $totalChecked++

            try {
                $pde = Join-Path $dir 'AvatarStar.pde'
                if ([System.IO.File]::Exists($pde)) {
                    $obj = Resolve-PdeCandidate $pde
                    if ($null -ne $obj) {
                        return [PSCustomObject]@{
                            Candidate=[PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source='全磁碟搜尋'; PreferredExe='' }
                            TimedOut=$false
                        }
                    }
                }
            } catch {}

            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                    Assert-NotCancelled
                    try {
                        # Check the directory itself before reparse-point descent rules.
                        # A valid game directory may itself be a junction.
                        $childPde = Join-Path $sub 'AvatarStar.pde'
                        if ([System.IO.File]::Exists($childPde)) {
                            $obj = Resolve-PdeCandidate $childPde
                            if ($null -ne $obj) {
                                return [PSCustomObject]@{
                                    Candidate=[PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source='全磁碟搜尋'; PreferredExe='' }
                                    TimedOut=$false
                                }
                            }
                        }
                        $attr = [System.IO.File]::GetAttributes($sub)
                        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $state.Stack.Push($sub)
                    } catch {}
                }
            } catch {}

            if (([DateTime]::UtcNow - $lastUpdate).TotalMilliseconds -ge 250) {
                $pct = 52 + [Math]::Min(34, [Math]::Floor([Math]::Log10([Math]::Max(1, $totalChecked)) * 8))
                Set-ProgressState $pct ('全磁碟搜尋 ' + [string]$state.Root)
                $lastUpdate = [DateTime]::UtcNow
            }
        }
        if ($active -eq 0) { break }
    }
    return [PSCustomObject]@{ Candidate=$null; TimedOut=$false }
}

function Save-Candidates([object[]]$Candidates) {
    if ([string]::IsNullOrWhiteSpace($CandidateFile)) { throw '候選安裝暫存路徑無效。' }
    $payload = @($Candidates | ForEach-Object { [ordered]@{ Folder=$_.Folder; Pde=$_.Pde; Source=$_.Source; PreferredExe=$_.PreferredExe } })
    [System.IO.File]::WriteAllText($CandidateFile, ($payload | ConvertTo-Json -Compress -Depth 4), $Utf8NoBom)
}

function Read-SavedCandidates {
    if ([string]::IsNullOrWhiteSpace($CandidateFile) -or -not (Test-Path -LiteralPath $CandidateFile -PathType Leaf)) { return @() }
    $raw = [System.IO.File]::ReadAllText($CandidateFile, $Utf8NoBom)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Write-InfoResult {
    param($Info, [string]$Status='OK', [string]$Message='')
    Write-Result ([ordered]@{
        STATUS=$Status; MESSAGE=$Message; FOLDER=$Info.Folder; PDE=$Info.Pde; PDESTATUS=$Info.PdeStatus;
        SIZE=$Info.Size; HASH=$Info.Hash; STATE=$Info.State; LABEL=$Info.Label; COMPAT=$Info.Compat;
        GAMEVERSION=$Info.GameVersion; SOURCE=$Info.Source; MATCHCOUNT=$Info.MatchCount;
        PATCH1OFFSET=$Info.Offset1; PATCH2OFFSET=$Info.Offset2; PATCH1BYTES=$Info.Bytes1; PATCH2BYTES=$Info.Bytes2;
        KNOWNSAMPLE=$Info.KnownSample; RECOVERY=$Info.Recovery; RECOVERYMESSAGE=$Info.RecoveryMessage;
        ANALYSISMETHOD=$Info.AnalysisMethod; STABLE=$Info.Stable; ANALYSISERROR=$Info.AnalysisError
    })
}

function Handle-DetectionCandidates([object[]]$Candidates, [int]$StartPercent, [int]$EndPercent) {
    $items = @($Candidates | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return $false }
    if ($items.Count -gt 1) {
        Save-Candidates $items
        Set-ProgressState 100 '找到多個安裝，等待選擇'
        Write-Result ([ordered]@{ STATUS='MULTIPLE'; MESSAGE='找到多個可能的 Avatar Star 安裝。'; CANDIDATECOUNT=$items.Count })
        return $true
    }
    $c = $items[0]
    try { if ($DiscoveryTraceFile) { [System.IO.File]::WriteAllText($DiscoveryTraceFile, [string]$c.Pde, $Utf8NoBom) } } catch {}
    $info = Inspect-Candidate -Candidate $c -StartPercent $StartPercent -EndPercent $EndPercent
    if ([string]$info.PdeStatus -ne 'FOUND') {
        Clear-CurrentSelection
        return $false
    }
    Save-CurrentSelection $c
    Set-ProgressState 100 '已找到遊戲'
    Write-InfoResult $info 'OK' ''
    return $true
}

function Game-Is-Running([string]$Folder) {
    $folderNorm = Normalize-FolderPath $Folder
    $paths = New-Object System.Collections.ArrayList
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and ($_.Name -ieq 'client.exe' -or $_.Name -ieq 'AvatarStar.exe')
        }
        foreach ($proc in $procs) { if ($proc.ExecutablePath) { [void]$paths.Add([string]$proc.ExecutablePath) } }
    } catch {}
    foreach ($name in @('client','AvatarStar')) {
        try {
            foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try { if ($proc.Path) { [void]$paths.Add([string]$proc.Path) } } catch {}
            }
        } catch {}
    }
    foreach ($path in ($paths | Select-Object -Unique)) {
        try {
            $resolved = Resolve-PdeCandidate $path
            if ($null -ne $resolved -and $resolved.Folder -ieq $folderNorm) { return $true }
        } catch {}
    }
    return $false
}

function Get-BackupCandidates([string]$Pde) {
    $list = New-Object System.Collections.ArrayList
    $legacy = $Pde + '.sensitivity-tool.original'
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { [void]$list.Add($legacy) }
    $folder = Split-Path -LiteralPath $Pde -Parent
    $leaf = [System.IO.Path]::GetFileName($Pde)
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter ($leaf + '.astbak.*.pde') -File -ErrorAction SilentlyContinue)) {
            [void]$list.Add($f.FullName)
        }
    } catch {}
    return @($list | Select-Object -Unique)
}

function Get-FileHashWithProgress([string]$Path, [int]$StartPercent, [int]$EndPercent, [string]$Stage) {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return (Analyze-Stream -Stream $fs -StartPercent $StartPercent -EndPercent $EndPercent -Stage $Stage) }
    finally { $fs.Dispose() }
}

function Ensure-FullBackup {
    param([System.IO.FileStream]$SourceStream, [string]$Pde, [string]$PreHash, [Int64]$PreSize)
    $prefix = $PreHash.Substring(0, [Math]::Min(16, $PreHash.Length))
    $backup = $Pde + '.astbak.' + $prefix + '.pde'
    if (Test-Path -LiteralPath $backup -PathType Leaf) {
        $existing = Get-FileHashWithProgress -Path $backup -StartPercent 42 -EndPercent 50 -Stage '驗證既有完整備份'
        if ([Int64]$existing.Size -eq $PreSize -and [string]$existing.Hash -eq $PreHash) { return $backup }
        throw '同名完整備份存在但內容不符；已停止修改，且沒有覆蓋該備份。'
    }

    $root = [System.IO.Path]::GetPathRoot($Pde)
    if ($root -and -not $root.StartsWith('\')) {
        $drive = $null
        try { $drive = New-Object System.IO.DriveInfo -ArgumentList $root } catch { $drive = $null }
        if ($null -ne $drive -and $drive.IsReady -and $drive.AvailableFreeSpace -lt ($PreSize + 67108864)) {
            throw '磁碟可用空間不足，無法建立完整原版備份。'
        }
    }

    $tmp = $backup + '.tmp'
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $dst = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        [void]$SourceStream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $dst = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] 8388608
        $done = [Int64]0
        $last = [DateTime]::UtcNow.AddSeconds(-1)
        while (($read = $SourceStream.Read($buf, 0, $buf.Length)) -gt 0) {
            Assert-NotCancelled
            $dst.Write($buf, 0, $read)
            $done += $read
            if ($done -lt $PreSize) { [void]$sha.TransformBlock($buf, 0, $read, $buf, 0) }
            else { [void]$sha.TransformFinalBlock($buf, 0, $read) }
            if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 250) {
                $pct = 50 + [Math]::Floor(18 * ($done / [double]$PreSize))
                Set-ProgressState $pct '建立完整原版備份'
                $last = [DateTime]::UtcNow
            }
        }
        if ($PreSize -eq 0) { [void]$sha.TransformFinalBlock($buf, 0, 0) }
        $dst.Flush($true)
        $copyHash = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        if ($done -ne $PreSize -or $copyHash -ne $PreHash) { throw '完整備份建立後與修改前 PDE 不一致。' }
        $dst.Dispose(); $dst = $null
        Move-Item -LiteralPath $tmp -Destination $backup -Force
        return $backup
    }
    catch {
        if ($null -ne $dst) { $dst.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    finally { $sha.Dispose() }
}

function Classify-Analysis($Analysis) {
    $state = 'Unknown'
    $match = $null
    if ($Analysis.MatchCount -eq 1) {
        $match = $Analysis.Matches[0]
        $state = Get-StateNameFromCode ([int]$match.StateCode)
    }
    elseif ($Analysis.MatchCount -gt 1) { $state = 'Ambiguous' }
    return [PSCustomObject]@{ State=$state; Match=$match }
}

function Build-InfoFromAnalysis {
    param(
        $Candidate,
        $Analysis,
        [string]$Recovery = 'NO',
        [string]$RecoveryMessage = '',
        [string]$Stable = 'YES'
    )
    $class = Classify-Analysis $Analysis
    $state = [string]$class.State
    $o1 = ''; $o2 = ''; $b1 = ''; $b2 = ''
    if ($Analysis.MatchCount -eq 1 -and $null -ne $class.Match) {
        $o1 = ('0x{0:X}' -f [Int64]$class.Match.Offset1)
        $o2 = ('0x{0:X}' -f [Int64]$class.Match.Offset2)
        switch ([int]$class.Match.StateCode) {
            1 { $b1 = Bytes-ToHex $Original1; $b2 = Bytes-ToHex $Original2 }
            2 { $b1 = Bytes-ToHex $Mode9911; $b2 = Bytes-ToHex $Mode9912 }
            3 { $b1 = Bytes-ToHex $Original1; $b2 = Bytes-ToHex $Mode9912 }
            4 { $b1 = Bytes-ToHex $Mode9911; $b2 = Bytes-ToHex $Original2 }
        }
    }
    $compat = 'UNVERIFIED'
    if ($Recovery -eq 'YES') { $compat = 'RECOVERY' }
    elseif ($Stable -eq 'YES' -and $Analysis.MatchCount -eq 1 -and ($state -eq 'Original' -or $state -eq 'Mode991')) { $compat = 'SUPPORTED' }
    return [PSCustomObject]@{
        Status='OK'; Folder=[string]$Candidate.Folder; Pde=[string]$Candidate.Pde; PdeStatus='FOUND';
        Size=[Int64]$Analysis.Size; Hash=[string]$Analysis.Hash; State=$state; Label=(Get-StateLabel $state);
        Compat=$compat; GameVersion=(Get-GameVersion ([string]$Candidate.Folder) ([string]$Candidate.PreferredExe));
        Source=[string]$Candidate.Source; MatchCount=[int]$Analysis.MatchCount; Offset1=$o1; Offset2=$o2;
        Bytes1=$b1; Bytes2=$b2; KnownSample=(Get-KnownSampleLabel ([string]$Analysis.Hash));
        Recovery=$Recovery; RecoveryMessage=$RecoveryMessage; AnalysisMethod='Dynamic paired signature'; Stable=$Stable; AnalysisError=''
    }
}

function Patch-To([string]$Variant) {
    $c = Resolve-ActionCandidate
    if (Game-Is-Running $c.Folder) { throw '遊戲目前正在執行，請先完全關閉遊戲。' }
    Assert-NotCancelled
    Set-ProgressState 3 '取得 PDE 獨占鎖並重新驗證'

    $fs = $null
    $preHash = ''
    $preSize = [Int64]0
    $snapshot1 = $null
    $snapshot2 = $null
    $offset1 = [Int64]0
    $offset2 = [Int64]0
    $journalWritten = $false
    $target1 = $null
    $target2 = $null
    try {
        $fs = [System.IO.File]::Open($c.Pde, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $pre = Analyze-Stream -Stream $fs -StartPercent 5 -EndPercent 38 -Stage '修改前驗證 PDE / SHA-256 / 靈敏度結構'
        $preHash = [string]$pre.Hash
        $preSize = [Int64]$pre.Size
        $class = Classify-Analysis $pre
        if ($pre.MatchCount -ne 1 -or ($class.State -ne 'Original' -and $class.State -ne 'Mode991')) {
            throw '沒有找到唯一且可驗證的靈敏度結構，已拒絕修改。'
        }
        $offset1 = [Int64]$class.Match.Offset1
        $offset2 = [Int64]$class.Match.Offset2

        $journal = Read-Transaction $c.Pde
        if ($null -ne $journal) {
            throw '偵測到未完成的修改交易；請先使用「修復中斷交易」。'
        }

        $snapshot1 = Read-AtStream $fs $offset1 8
        $snapshot2 = Read-AtStream $fs $offset2 8
        if ($Variant -eq 'Mode991') {
            if ($class.State -eq 'Mode991') {
                $info = Build-InfoFromAnalysis -Candidate $c -Analysis $pre
                $fs.Dispose(); $fs = $null
                Set-ProgressState 100 '目前已是 1~991 模式'
                return [PSCustomObject]@{ Status='OK'; Message='目前已經是 1~991 模式。'; Info=$info }
            }
            if ($class.State -ne 'Original') { throw '目前 PDE 不是可驗證的官方原版，已拒絕套用 1~991。' }
            $target1 = $Mode9911; $target2 = $Mode9912
            [void](Ensure-FullBackup -SourceStream $fs -Pde $c.Pde -PreHash $preHash -PreSize $preSize)
        }
        elseif ($Variant -eq 'Original') {
            if ($class.State -eq 'Original') {
                $info = Build-InfoFromAnalysis -Candidate $c -Analysis $pre
                $fs.Dispose(); $fs = $null
                Set-ProgressState 100 '目前已是官方原版'
                return [PSCustomObject]@{ Status='OK'; Message='目前已經是官方原版。'; Info=$info }
            }
            if ($class.State -ne 'Mode991') { throw '目前 PDE 不是可驗證的 1~991 模式，已拒絕還原。' }
            $target1 = $Original1; $target2 = $Original2
        }
        else { throw '未知 patch 模式。' }

        Assert-NotCancelled
        if (Game-Is-Running $c.Folder) { throw '遊戲在修改前被啟動，已停止修改。' }

        [void](Write-Transaction -Pde $c.Pde -PreHash $preHash -PreSize $preSize -Offset1 $offset1 -Offset2 $offset2 -Before1 $snapshot1 -Before2 $snapshot2 -Target1 $target1 -Target2 $target2 -TargetState $Variant)
        $journalWritten = $true
        $journalCheck = Read-Transaction $c.Pde
        if ($null -eq $journalCheck -or ($journalCheck.PSObject.Properties.Name -contains 'Invalid' -and $journalCheck.Invalid)) {
            throw '交易紀錄寫入後無法讀回驗證。'
        }
        Assert-NotCancelled
        if (Game-Is-Running $c.Folder) { throw '遊戲在修改前被啟動，已停止修改。' }

        Set-ProgressState 72 '寫入兩處靈敏度 patch'
        Write-AtStream $fs $offset1 $target1
        Write-AtStream $fs $offset2 $target2
        $fs.Flush($true)

        $verify1 = Read-AtStream $fs $offset1 8
        $verify2 = Read-AtStream $fs $offset2 8
        if (-not (Bytes-Equal $verify1 $target1) -or -not (Bytes-Equal $verify2 $target2)) {
            throw '寫入後讀回的 patch bytes 不一致。'
        }

        Assert-NotCancelled
        $post = Analyze-Stream -Stream $fs -StartPercent 76 -EndPercent 98 -Stage '修改後完整驗證' -ReplaceOffset1 $offset1 -ReplaceBytes1 $snapshot1 -ReplaceOffset2 $offset2 -ReplaceBytes2 $snapshot2
        $postClass = Classify-Analysis $post
        if ([Int64]$post.Size -ne $preSize) { throw '修改後 PDE 檔案大小發生變化。' }
        if ($post.RebuiltHash -ne $preHash) { throw '修改後偵測到兩處 patch 以外的內容發生變化。' }
        if ($post.MatchCount -ne 1 -or [Int64]$postClass.Match.Offset1 -ne $offset1 -or [Int64]$postClass.Match.Offset2 -ne $offset2) {
            throw '修改後無法重新定位唯一的靈敏度結構。'
        }
        if ($Variant -eq 'Mode991' -and $postClass.State -ne 'Mode991') { throw '修改後模式驗證不是 1~991。' }
        if ($Variant -eq 'Original' -and $postClass.State -ne 'Original') { throw '修改後模式驗證不是官方原版。' }

        Remove-Transaction $c.Pde
        $journalWritten = $false
        $info = Build-InfoFromAnalysis -Candidate $c -Analysis $post
        $fs.Dispose(); $fs = $null
        Set-ProgressState 100 '修改完成並通過完整驗證'
        return [PSCustomObject]@{ Status='OK'; Message='修改完成；兩處 patch 與其餘 PDE 內容均已驗證。'; Info=$info }
    }
    catch {
        $failure = $_.Exception.Message
        if ($null -ne $fs -and $journalWritten -and $null -ne $snapshot1 -and $null -ne $snapshot2) {
            try {
                Set-ProgressState 88 '執行 transaction rollback'
                Write-AtStream $fs $offset1 $snapshot1
                Write-AtStream $fs $offset2 $snapshot2
                $fs.Flush($true)
                $rollback = Analyze-Stream -Stream $fs -StartPercent 89 -EndPercent 99 -Stage '驗證 rollback' -IgnoreCancellation
                if ([Int64]$rollback.Size -ne $preSize -or [string]$rollback.Hash -ne $preHash) {
                    throw 'rollback 後完整 SHA-256 無法回到修改前狀態。'
                }
                Remove-Transaction $c.Pde
                $journalWritten = $false
                throw ('修改失敗，但已完整回復修改前狀態。原因：' + $failure)
            }
            catch {
                if ($_.Exception.Message -like '修改失敗，但已完整回復*') { throw }
                throw ('修改失敗，且 rollback 無法證明完整復原。請勿啟動遊戲，保留交易紀錄與備份。原始錯誤：' + $failure + '；rollback：' + $_.Exception.Message)
            }
        }
        throw
    }
    finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}


function Recover-FromJournal($Candidate, $Journal) {
    if ($Journal.PSObject.Properties.Name -contains 'Invalid' -and $Journal.Invalid) {
        throw ('交易紀錄無法解析，無法自動復原：' + [string]$Journal.Error)
    }

    $preHash = ([string]$Journal.PreHash).ToLowerInvariant()
    $preSize = [Int64]$Journal.PreSize
    $o1 = [Int64]$Journal.Offset1
    $o2 = [Int64]$Journal.Offset2
    $b1 = Hex-ToBytes ([string]$Journal.Before1)
    $b2 = Hex-ToBytes ([string]$Journal.Before2)
    $t1 = Hex-ToBytes ([string]$Journal.Target1)
    $t2 = Hex-ToBytes ([string]$Journal.Target2)
    if ($b1.Length -ne 8 -or $b2.Length -ne 8 -or $t1.Length -ne 8 -or $t2.Length -ne 8) {
        throw '交易紀錄中的 patch bytes 無效。'
    }
    if ($o1 -lt 0 -or $o2 -lt 0 -or ($o2 - $o1) -ne $PatchDelta) {
        throw '交易紀錄中的 patch offset 無效。'
    }

    if (Game-Is-Running $Candidate.Folder) {
        throw '遊戲目前正在執行，請先完全關閉遊戲。'
    }

    $fs = [System.IO.File]::Open(
        $Candidate.Pde,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        if ($fs.Length -ne $preSize) {
            throw '目前 PDE 大小與交易前不一致，無法安全判斷交易狀態。'
        }

        # One exclusive snapshot proves both the current complete hash and
        # whether changing only the two recorded ranges can reconstruct preHash.
        $proof = Analyze-Stream -Stream $fs -StartPercent 8 -EndPercent 68 -Stage '驗證中斷交易狀態' `
            -ReplaceOffset1 $o1 -ReplaceBytes1 $b1 -ReplaceOffset2 $o2 -ReplaceBytes2 $b2

        # Journal written, but PDE never changed (or was already rolled back).
        if ([string]$proof.Hash -eq $preHash) {
            Remove-Transaction $Candidate.Pde
            $info = Build-InfoFromAnalysis -Candidate $Candidate -Analysis $proof
            Set-ProgressState 100 '交易紀錄已安全清理'
            return [PSCustomObject]@{
                Status='OK'
                Message='交易紀錄存在，但 PDE 已是修改前的完整狀態；已安全清理交易紀錄。'
                Info=$info
            }
        }

        $now1 = Read-AtStream $fs $o1 8
        $now2 = Read-AtStream $fs $o2 8

        # If the exact intended target is present and replacing only those bytes
        # reconstructs the exact preHash, the write itself completed. Preserve
        # the completed target and only clean the leftover journal.
        if ((Bytes-Equal $now1 $t1) -and (Bytes-Equal $now2 $t2) -and [string]$proof.RebuiltHash -eq $preHash) {
            Remove-Transaction $Candidate.Pde
            $info = Build-InfoFromAnalysis -Candidate $Candidate -Analysis $proof
            Set-ProgressState 100 '已確認交易完整完成'
            return [PSCustomObject]@{
                Status='OK'
                Message='交易寫入已完整完成；只有交易紀錄清理被中斷，已保留目前模式並清理紀錄。'
                Info=$info
            }
        }

        # A partial/mixed write is recoverable only when replacing exactly the
        # recorded two ranges reconstructs the byte-for-byte pre-transaction file.
        if ([string]$proof.RebuiltHash -ne $preHash) {
            throw '目前 PDE 不只交易紀錄的兩處 patch 區域不同；已拒絕自動寫回。'
        }

        Assert-NotCancelled
        if (Game-Is-Running $Candidate.Folder) {
            throw '遊戲在復原前被啟動，已停止寫入。'
        }

        Set-ProgressState 70 '依交易紀錄回復兩處 bytes'
        Write-AtStream $fs $o1 $b1
        Write-AtStream $fs $o2 $b2
        $fs.Flush($true)

        $verify = Analyze-Stream -Stream $fs -StartPercent 72 -EndPercent 98 -Stage '驗證交易復原' -IgnoreCancellation
        if ([Int64]$verify.Size -ne $preSize -or [string]$verify.Hash -ne $preHash) {
            throw '復原後完整 SHA-256 無法回到交易前狀態。'
        }

        Remove-Transaction $Candidate.Pde
        $info = Build-InfoFromAnalysis -Candidate $Candidate -Analysis $verify
        Set-ProgressState 100 '交易復原完成'
        return [PSCustomObject]@{
            Status='OK'
            Message='未完成 / 部分完成的修改交易已完整回復到修改前狀態。'
            Info=$info
        }
    }
    finally {
        $fs.Dispose()
    }
}

function Recover-FromBackup($Candidate) {
    if (Game-Is-Running $Candidate.Folder) { throw '遊戲目前正在執行，請先完全關閉遊戲。' }
    $backups = @(Get-BackupCandidates $Candidate.Pde)
    if ($backups.Count -eq 0) { throw '沒有可用的完整原版備份，無法證明安全復原。' }

    $current = [System.IO.File]::Open($Candidate.Pde, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $i = 0
        foreach ($backupPath in $backups) {
            Assert-NotCancelled
            $i++
            $start = 5 + [Math]::Floor((($i - 1) / [double]$backups.Count) * 55)
            $end = 5 + [Math]::Floor(($i / [double]$backups.Count) * 55)
            $bf = [System.IO.File]::Open($backupPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $ba = Analyze-Stream -Stream $bf -StartPercent $start -EndPercent $end -Stage '驗證完整原版備份'
                $bc = Classify-Analysis $ba
                if ($ba.MatchCount -ne 1 -or $bc.State -ne 'Original') { continue }
                if ([Int64]$ba.Size -ne $current.Length) { continue }
                $bo1 = [Int64]$bc.Match.Offset1; $bo2 = [Int64]$bc.Match.Offset2
                $bb1 = Read-AtStream $bf $bo1 8; $bb2 = Read-AtStream $bf $bo2 8
                $rebuild = Analyze-Stream -Stream $current -StartPercent 60 -EndPercent 88 -Stage '比對目前 PDE 與原版備份' -ReplaceOffset1 $bo1 -ReplaceBytes1 $bb1 -ReplaceOffset2 $bo2 -ReplaceBytes2 $bb2
                if ($rebuild.RebuiltHash -ne $ba.Hash) { continue }
                Assert-NotCancelled
                if (Game-Is-Running $Candidate.Folder) { throw '遊戲在復原前被啟動，已停止寫入。' }

                Set-ProgressState 89 '依完整備份修復兩處 bytes'
                Write-AtStream $current $bo1 $bb1
                Write-AtStream $current $bo2 $bb2
                $current.Flush($true)
                $verify = Analyze-Stream -Stream $current -StartPercent 90 -EndPercent 98 -Stage '驗證備份復原' -IgnoreCancellation
                if ($verify.Hash -ne $ba.Hash) { throw '寫回後完整 SHA-256 與原版備份不一致。' }
                Remove-Transaction $Candidate.Pde
                $info = Build-InfoFromAnalysis -Candidate $Candidate -Analysis $verify
                $current.Dispose(); $current = $null
                Set-ProgressState 100 '備份復原完成'
                return [PSCustomObject]@{ Status='OK'; Message='已使用可證明一致的完整原版備份修復 PDE。'; Info=$info }
            }
            finally { $bf.Dispose() }
        }
        throw '找到備份，但沒有任何一份能證明目前 PDE 只在靈敏度 patch 區域不同；已拒絕自動覆寫。'
    }
    finally { if ($null -ne $current) { $current.Dispose() } }
}

function Recover-Current {
    $c = Resolve-ActionCandidate
    $journal = Read-Transaction $c.Pde
    if ($null -ne $journal) { return Recover-FromJournal $c $journal }
    return Recover-FromBackup $c
}


function Get-KnownOffsetDiagnosticBytes([string]$Pde) {
    $r = [ordered]@{ Offset1Bytes='OUT_OF_RANGE'; Offset2Bytes='OUT_OF_RANGE' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open(
            $Pde,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        if ($KnownOffset1 -ge 0 -and ($KnownOffset1 + 8) -le $fs.Length) {
            $r.Offset1Bytes = Bytes-ToHex (Read-AtStream $fs $KnownOffset1 8)
        }
        if ($KnownOffset2 -ge 0 -and ($KnownOffset2 + 8) -le $fs.Length) {
            $r.Offset2Bytes = Bytes-ToHex (Read-AtStream $fs $KnownOffset2 8)
        }
    }
    catch {
        $r.Offset1Bytes = 'READ_ERROR'
        $r.Offset2Bytes = 'READ_ERROR'
    }
    finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
    return [PSCustomObject]$r
}

function Get-DiagnosticPath {
    $desktop = Get-OriginalUserShellFolder 'Desktop'
    if ([string]::IsNullOrWhiteSpace($desktop) -and $OriginalUserProfile) { $desktop = Join-Path $OriginalUserProfile 'Desktop' }
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        $desktop = $OriginalUserProfile
    }
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        throw '無法找到原始使用者可寫入的桌面 / 使用者資料夾。'
    }
    return Join-Path $desktop ('AvatarStar_Sensitivity_Diagnostic_' + [DateTime]::Now.ToString('yyyyMMdd_HHmmss') + '.txt')
}

function Export-Diagnostic {
    $c = Resolve-ActionCandidate
    $info = Inspect-Candidate -Candidate $c -StartPercent 5 -EndPercent 92
    $knownOffsetBytes = Get-KnownOffsetDiagnosticBytes $c.Pde
    $path = Get-DiagnosticPath
    $lines = @(
        'Avatar Star Sensitivity Tool Diagnostic',
        ('ToolVersion=' + $ToolVersion),
        ('Created=' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')),
        ('GameFolder=' + $info.Folder),
        ('GameVersion=' + $info.GameVersion),
        ('DetectionSource=' + $info.Source),
        ('PdeSize=' + $info.Size),
        ('PdeSha256=' + $info.Hash),
        ('KnownSample=' + $info.KnownSample),
        ('AnalysisMethod=' + $info.AnalysisMethod),
        ('Stable=' + $info.Stable),
        ('MatchCount=' + $info.MatchCount),
        ('State=' + $info.State),
        ('Compatibility=' + $info.Compat),
        ('Patch1Offset=' + $info.Offset1),
        ('Patch2Offset=' + $info.Offset2),
        ('Patch1Bytes=' + $info.Bytes1),
        ('Patch2Bytes=' + $info.Bytes2),
        ('Recovery=' + $info.Recovery),
        ('RecoveryMessage=' + $info.RecoveryMessage),
        ('AnalysisError=' + $info.AnalysisError),
        ('KnownSampleSize=' + $KnownSampleSize),
        ('PdeSizeMatchesKnownSample=' + $(if ([Int64]$info.Size -eq $KnownSampleSize) { 'YES' } else { 'NO' })),
        ('KnownSampleOffset1=0x{0:X}' -f $KnownOffset1),
        ('KnownSampleOffset1CurrentBytes=' + $knownOffsetBytes.Offset1Bytes),
        ('KnownSampleOffset2=0x{0:X}' -f $KnownOffset2),
        ('KnownSampleOffset2CurrentBytes=' + $knownOffsetBytes.Offset2Bytes),
        'CompatibilityGate=UNIQUE_DYNAMIC_PAIRED_SIGNATURE',
        'KnownSizeHashOffsetsAreCompatibilityGate=NO'
    )
    [System.IO.File]::WriteAllLines($path, $lines, $Utf8NoBom)
    Set-ProgressState 100 '診斷報告已匯出'
    Write-InfoResult $info 'OK' ('診斷報告已儲存：' + $path)
}

try {
    Assert-NotCancelled
    Touch-Heartbeat
    switch ($Action) {
        'Locate' {
            Clear-CurrentSelection
            if ($DiscoveryTraceFile) { Remove-Item -LiteralPath $DiscoveryTraceFile -Force -ErrorAction SilentlyContinue }
            if ($CandidateFile) { Remove-Item -LiteralPath $CandidateFile -Force -ErrorAction SilentlyContinue }
            Set-ProgressState 2 '開始偵測遊戲位置'

            $tier = Find-RunningCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            $tier = Find-PersistentCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            $tier = Find-AppDataCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            $tier = Find-RegistryCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            $tier = Find-ShortcutCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            $tier = Find-CommonCandidates
            if (Handle-DetectionCandidates $tier 45 99) { break }

            Set-ProgressState 50 '快速偵測未找到 PDE，開始全磁碟 fallback'
            $full = Find-FullDiskCandidate
            if ($null -ne $full.Candidate) {
                [void](Handle-DetectionCandidates @($full.Candidate) 87 99)
                break
            }

            Set-ProgressState 100 '沒有找到 AvatarStar.pde'
            Write-Result ([ordered]@{
                STATUS='NOTFOUND'
                MESSAGE=$(if ($full.TimedOut) { '沒有找到 AvatarStar.pde；部分磁碟搜尋達到安全逾時上限。' } else { '沒有找到 AvatarStar.pde。' })
                SEARCHINCOMPLETE=$(if ($full.TimedOut) { 'YES' } else { 'NO' })
            })
        }

        'Inspect' {
            Clear-CurrentSelection
            Set-ProgressState 5 '驗證指定遊戲位置'
            $obj = Resolve-ManualPdeCandidate $Target
            if ($null -eq $obj) {
                Set-ProgressState 100 '找不到 AvatarStar.pde'
                Write-Result ([ordered]@{ STATUS='NOTFOUND'; MESSAGE='指定位置找不到 AvatarStar.pde。' })
                break
            }
            $c = [PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source='手動指定'; PreferredExe=$(if ((Test-Path -LiteralPath $Target -PathType Leaf) -and (([IO.Path]::GetFileName($Target) -ieq 'client.exe') -or ([IO.Path]::GetFileName($Target) -ieq 'AvatarStar.exe'))) { $Target } else { '' }) }
            $info = Inspect-Candidate -Candidate $c -StartPercent 10 -EndPercent 99
            if ([string]$info.PdeStatus -ne 'FOUND') {
                Clear-CurrentSelection
                Set-ProgressState 100 '指定的 AvatarStar.pde 已消失'
                Write-Result ([ordered]@{ STATUS='NOTFOUND'; MESSAGE='指定的 AvatarStar.pde 在驗證期間已不存在。' })
                break
            }
            Save-CurrentSelection $c
            Set-ProgressState 100 '指定位置驗證完成'
            Write-InfoResult $info 'OK' ''
        }

        'SelectCandidate' {
            Clear-CurrentSelection
            $items = @(Read-SavedCandidates)
            if ($items.Count -eq 0) { throw '候選安裝清單已失效，請重新偵測。' }
            $index = 0
            if (-not [int]::TryParse($Value, [ref]$index)) { throw '選擇值無效。' }
            if ($index -lt 1 -or $index -gt $items.Count) { throw '選擇值超出候選範圍。' }
            $raw = $items[$index - 1]
            $obj = Resolve-PdeCandidate ([string]$raw.Pde)
            if ($null -eq $obj) { throw '選擇的安裝已不存在。' }
            $c = [PSCustomObject]@{ Folder=$obj.Folder; Pde=$obj.Pde; Source=[string]$raw.Source; PreferredExe=[string]$raw.PreferredExe }
            $info = Inspect-Candidate -Candidate $c -StartPercent 10 -EndPercent 99
            if ([string]$info.PdeStatus -ne 'FOUND') {
                Clear-CurrentSelection
                throw '選擇的 AvatarStar.pde 在驗證期間已不存在，請重新偵測。'
            }
            Save-CurrentSelection $c
            Set-ProgressState 100 '安裝選擇完成'
            Write-InfoResult $info 'OK' ''
        }

        'Apply991' {
            $r = Patch-To 'Mode991'
            Write-InfoResult $r.Info $r.Status $r.Message
        }

        'Restore' {
            $r = Patch-To 'Original'
            Write-InfoResult $r.Info $r.Status $r.Message
        }

        'Recover' {
            $r = Recover-Current
            Write-InfoResult $r.Info $r.Status $r.Message
        }

        'Diagnostic' {
            Export-Diagnostic
        }

        'Convert' {
            Set-ProgressState 20 '計算靈敏度換算'
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $number = [double]::Parse($Value, $culture)
            switch ($ConvertMode) {
                'OldTo991' {
                    if ($number -lt 1 -or $number -gt 100) { throw '原版靈敏度請輸入 1~100。' }
                    $result = 10 * $number - 9
                }
                'Mode991ToOld' {
                    if ($number -lt 1 -or $number -gt 991) { throw '1~991 靈敏度請輸入 1~991。' }
                    $result = ($number + 9) / 10
                }
                default { throw '未知換算模式。' }
            }
            Set-ProgressState 100 '計算完成'
            Write-Result ([ordered]@{ STATUS='OK'; RESULT=$result.ToString('0.########', $culture) })
        }

        'VisualMatch' {
            Set-ProgressState 20 '計算瞄準鏡 1:1 理論值'
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $inputValue = [double]::Parse($Value, $culture)
            $zoomValue = [double]::Parse($Zoom, $culture)
            if ($zoomValue -le 0 -or $zoomValue -gt 100) { throw '瞄準鏡倍率必須大於 0 且不超過 100。' }
            switch ($ConvertMode) {
                'Mode991' {
                    if ($inputValue -lt 1 -or $inputValue -gt 991) { throw '1~991 一般靈敏度請輸入 1~991。' }
                    $hipOld = ($inputValue + 9) / 10
                    $adsOld = $hipOld / $zoomValue
                    $theory = 10 * $adsOld - 9
                    $recommended = [Math]::Round($theory, 0, [MidpointRounding]::AwayFromZero)
                    $reachable = ($recommended -ge 1 -and $recommended -le 991)
                }
                'Original' {
                    if ($inputValue -lt 1 -or $inputValue -gt 100) { throw '原版一般靈敏度請輸入 1~100。' }
                    $theory = $inputValue / $zoomValue
                    $recommended = [Math]::Round($theory, 0, [MidpointRounding]::AwayFromZero)
                    $reachable = ($recommended -ge 1 -and $recommended -le 100)
                }
                default { throw '未知輸入模式。' }
            }
            Set-ProgressState 100 '計算完成'
            Write-Result ([ordered]@{
                STATUS='OK'; HIPINPUT=$inputValue.ToString('0.###', $culture);
                THEORY=$theory.ToString('0.###', $culture); RECOMMENDED=$recommended.ToString('0', $culture);
                REACHABLE=$(if ($reachable) { 'YES' } else { 'NO' })
            })
        }
    }
}
catch {
    Set-ProgressState 100 '執行失敗'
    Write-Result ([ordered]@{ STATUS='ERROR'; MESSAGE=$_.Exception.Message; CLEARSTATE=$(if ($ClearStateOnError) { 'YES' } else { 'NO' }) })
}
finally {
    Touch-Heartbeat
}
