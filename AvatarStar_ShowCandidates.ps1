param([Parameter(Mandatory=$true)][string]$SessionDir)
$enc950 = [System.Text.Encoding]::GetEncoding(950)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $enc950 } catch {}
$file = Join-Path $SessionDir 'candidates.json'
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { exit 1 }
try {
    $items = @(([System.IO.File]::ReadAllText($file, $Utf8NoBom)) | ConvertFrom-Json)
    $i = 0
    foreach ($item in $items) {
        $i++
        [Console]::WriteLine(('                     [{0}]  {1}' -f $i, [string]$item.Folder))
        [Console]::WriteLine(('                          來源：{0}' -f [string]$item.Source))
        [Console]::WriteLine('')
    }
    exit 0
}
catch { exit 2 }
