# Pre-recording safety checks. Dot-source this file; it runs nothing by itself.
# PowerShell 5.1 compatible.

$script:PreflightLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:PreflightLibDir) { $script:PreflightLibDir = $PSScriptRoot }

# ---- small mockable system wrappers ----
function Test-Cs2Running { return [bool](Get-Process -Name 'cs2' -ErrorAction SilentlyContinue) }
function Get-FreeSpaceGB([string]$path) {
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        if (-not $root) { return $null }
        $d = New-Object System.IO.DriveInfo($root)
        return [math]::Round($d.AvailableFreeSpace / 1GB, 1)
    } catch { return $null }
}
function Read-PreflightText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [System.IO.File]::ReadAllText($path)
}
function Get-GraphicsTablePath { return (Join-Path (Join-Path (Split-Path -Parent $script:PreflightLibDir) 'data') 'graphics_max.json') }
function Get-GraphicsTableAgeDays([string]$path) { return ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalDays }
function Get-DefaultSteamPath {
    foreach ($k in 'HKCU:\Software\Valve\Steam') {
        try { $p = (Get-ItemProperty $k -ErrorAction Stop).SteamPath; if ($p) { return ($p -replace '/', '\') } } catch {}
    }
    return 'C:\Program Files (x86)\Steam'
}

# ---- pure helpers ----
function New-PfCheck([string]$id, [string]$status, [string]$label, [string]$detail) {
    return [pscustomobject]@{ id = $id; status = $status; label = $label; detail = $detail }
}
function Test-PfSafePath([string]$p) {
    if ($p -match '[^\x20-\x7E]') { return 'The folder path has special letters (accents or umlauts). Pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p -match '[#%"''&^]') { return 'The folder path contains one of these characters: # % " '' & ^ . Pick a simpler path like C:\cs2-recorder\recordings.' }
    return $null
}
function Get-VideoCfgPathPf([string]$steam, [string]$id64) {
    if (-not $id64 -or $id64 -notmatch '^\d{17}$') { return $null }
    $acc = [int64]$id64 - 76561197960265728
    return (Join-Path $steam "userdata\$acc\730\local\cfg\cs2_video.txt")
}
function ConvertFrom-VideoCfg([string]$text) {
    $h = @{}
    foreach ($m in [regex]::Matches($text, '"([^"]+)"\s+"([^"]*)"')) { $h[$m.Groups[1].Value.ToLower()] = $m.Groups[2].Value }
    return $h
}
function Test-DemoPatch14192($demo) {
    if ($null -eq $demo) { return $false }
    $hdr = $demo
    if ($demo.PSObject.Properties['header'] -and $demo.header) { $hdr = $demo.header }
    foreach ($p in $hdr.PSObject.Properties) {
        if ($p.Name -match 'version|build|patch|network' -and "$($p.Value)" -match '(^|\D)14192(\D|$)') { return $true }
    }
    return $false
}

function Test-GraphicsCheck([string]$steam, [string]$id64) {
    $label = 'Graphics settings'
    $cfg = Get-VideoCfgPathPf $steam $id64
    if (-not $cfg) { return New-PfCheck 'graphics' 'warn' $label 'Could not locate the video settings file for this account.' }
    $text = Read-PreflightText $cfg
    if ($null -eq $text) { return New-PfCheck 'graphics' 'warn' $label 'No video settings file yet. Start CS2 once on this account and set graphics to maximum.' }
    $tbl = Get-GraphicsTablePath
    $raw = Read-PreflightText $tbl
    if ($null -eq $raw) { return New-PfCheck 'graphics' 'warn' $label 'Reference graphics table is missing, so settings were not compared.' }
    try { $t = $raw | ConvertFrom-Json } catch { return New-PfCheck 'graphics' 'warn' $label 'Reference graphics table is unreadable, so settings were not compared.' }
    $notes = @()
    $age = Get-GraphicsTableAgeDays $tbl
    if ($age -gt 30) { $notes += 'Reference table is older than 30 days.' }
    if (-not $t.verified) { $notes += 'Reference table is unverified.' }
    $cur = ConvertFrom-VideoCfg $text
    $bad = @()
    foreach ($r in @($t.settings)) {
        if (-not $r -or -not $r.key) { continue }
        $k = "$($r.key)".ToLower()
        if (-not $cur.ContainsKey($k)) { continue }          # unknown/missing key: no opinion
        if ($null -ne $r.equals -and "$($cur[$k])" -ne "$($r.equals)") {
            $lbl = $r.label; if (-not $lbl) { $lbl = $r.key }
            $bad += "$lbl ($($r.key)=$($cur[$k]), expected $($r.equals))"
        }
    }
    if ($bad.Count -gt 0) { return New-PfCheck 'graphics' 'warn' $label ((@($bad) + $notes) -join ' ') }
    if ($age -gt 30) { return New-PfCheck 'graphics' 'warn' $label ($notes -join ' ') }
    $d = 'Known settings look fine.'; if ($notes.Count) { $d += ' ' + ($notes -join ' ') }
    return New-PfCheck 'graphics' 'ok' $label $d
}

function Get-Preflight {
    param(
        [string]$AccountId,
        [ValidateSet('separate', 'main')][string]$AccountKind = 'separate',
        $DemoInfo = $null,
        [string]$OutDir,
        [string]$SteamPath
    )
    if (-not $SteamPath) { $SteamPath = Get-DefaultSteamPath }
    $c = @()

    if ($AccountKind -eq 'main') { $c += New-PfCheck 'account' 'block' 'Recording account' 'This is your main Steam account. Recording on it is blocked. Use a separate account.' }
    elseif (-not $AccountId) { $c += New-PfCheck 'account' 'block' 'Recording account' 'No account selected.' }
    else { $c += New-PfCheck 'account' 'ok' 'Recording account' 'Separate account selected.' }

    if (Test-Cs2Running) { $c += New-PfCheck 'cs2_closed' 'block' 'CS2 closed' 'CS2 is running. Close it before recording.' }
    else { $c += New-PfCheck 'cs2_closed' 'ok' 'CS2 closed' 'CS2 is not running.' }

    $c += Test-GraphicsCheck $SteamPath $AccountId

    if (Test-DemoPatch14192 $DemoInfo) { $c += New-PfCheck 'demo_patch' 'block' 'Demo version' 'This demo is from CS2 patch 14192 and crashes the game on load. Use a different demo.' }
    else { $c += New-PfCheck 'demo_patch' 'ok' 'Demo version' 'Demo version is fine.' }

    $probe = $OutDir; if (-not $probe) { $probe = $SteamPath }
    $gb = Get-FreeSpaceGB $probe
    if ($null -eq $gb) { $c += New-PfCheck 'disk_space' 'warn' 'Disk space' 'Could not read free disk space.' }
    elseif ($gb -lt 20) { $c += New-PfCheck 'disk_space' 'warn' 'Disk space' "Only $gb GB free on the output drive (20 GB or more recommended)." }
    else { $c += New-PfCheck 'disk_space' 'ok' 'Disk space' "$gb GB free." }

    if (-not $OutDir) { $c += New-PfCheck 'output_path' 'warn' 'Output folder' 'No output folder given.' }
    else {
        $e = Test-PfSafePath $OutDir
        if ($e) { $c += New-PfCheck 'output_path' 'block' 'Output folder' $e } else { $c += New-PfCheck 'output_path' 'ok' 'Output folder' 'Path is safe.' }
    }

    return [pscustomobject]@{ blocking = [bool](@($c | Where-Object { $_.status -eq 'block' }).Count); checks = $c }
}
