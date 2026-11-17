# CS2 Recorder - setup engine (checker + fixers + runner). Windows PowerShell 5.1, no Python needed.
# Dot-source to use the functions (nothing runs), or run directly:
#   powershell -File setup.ps1 -Check | -Fix <id> | -All      (prints JSON)
# All text in this file is plain ASCII on purpose.
param([switch]$Check, [string]$Fix = '', [switch]$All)

$script:SetupLib = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SetupTool = Split-Path -Parent $script:SetupLib
$script:SetupBase = Split-Path -Parent $script:SetupTool
$script:SetupData = Join-Path $script:SetupBase 'data'
$script:MinCsdm = [version]'3.20.1'
$script:PyOk = @('3.12', '3.13', '3.11', '3.14')
$script:PyUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'
$script:PyPage = 'https://www.python.org/downloads/release/python-31210/'
$script:CsdmPage = 'https://github.com/akiver/cs-demo-manager/releases/latest'
$script:FixOrder = @('python', 'venv', 'hlae', 'ffmpeg', 'csdm', 'postgres', 'postgres_path')

# ------------------------------------------------------------------ system wrappers (tests redefine these)
function Join-PathSafe([string]$a, [string]$b) { return [IO.Path]::Combine($a, $b) }   # Join-Path throws on a missing drive
function Test-PathSafe([string]$Path) { if (-not $Path) { return $false }; return (Test-Path -LiteralPath $Path) }
function Get-EnvSafe([string]$Name) { return [Environment]::GetEnvironmentVariable($Name) }
function Read-TextSafe([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) } } catch {}
    return $null
}
function Get-ServiceSafe([string]$Pattern) { return @(Get-Service -Name $Pattern -ErrorAction SilentlyContinue) }
function Start-ServiceSafe([string]$Name) { try { Start-Service -Name $Name -ErrorAction Stop; return $true } catch { return $false } }
function Start-ElevatedSafe([string]$Command) {
    # one UAC prompt; the command text is ours, never user input
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $Command
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}
function Get-CommandSafe([string]$Name) {
    $c = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    if ($c.Count -eq 0) { return $null }
    return $c
}
function Get-RegValueSafe([string]$Key, [string]$Name) {
    try { return (Get-ItemProperty -Path $Key -ErrorAction Stop).$Name } catch { return $null }
}
function Find-FilesSafe([string]$Pattern) {
    # $Pattern may contain wildcards in the path; returns objects with FullName / DirectoryName
    return @(Get-ChildItem -Path $Pattern -ErrorAction SilentlyContinue -Force | Where-Object { -not $_.PSIsContainer })
}
function Find-FilesInTree([string]$Root, [string]$Name) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue)
}
function Get-FileVersionSafe([string]$Dir) {
    $exe = Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'demo' } | Select-Object -First 1
    if (-not $exe) { return $null }
    $v = $exe.VersionInfo.ProductVersion
    if (-not $v) { $v = $exe.VersionInfo.FileVersion }
    try { return [version](($v -split '[^0-9.]')[0]) } catch { return $null }
}
function Invoke-ExternalSafe([string]$Exe, [string[]]$Arguments) {
    # returns @{ Code; Out }. Never throws; stderr noise does not count as failure.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        return @{ Code = $LASTEXITCODE; Out = (($out | ForEach-Object { "$_" }) -join "`n") }
    } catch { return @{ Code = -1; Out = "$_" } }
    finally { $ErrorActionPreference = $old }
}
function Get-JsonSafe([string]$Url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return (Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'cs2-recorder' } -TimeoutSec 30)
}
function Invoke-Download([string]$Url, [string]$Dest, [scriptblock]$OnBytes) {
    # downloads to Dest + '.part' (our own temp file) then renames; removes the .part on failure
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $part = $Dest + '.part'
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('User-Agent', 'cs2-recorder')
    try {
        $task = $wc.DownloadFileTaskAsync($Url, $part)
        while (-not $task.IsCompleted) {
            Start-Sleep -Milliseconds 400
            if ($OnBytes) { $len = 0; try { $len = (Get-Item -LiteralPath $part -ErrorAction Stop).Length } catch {}; & $OnBytes $len }
        }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
        Move-Item -LiteralPath $part -Destination $Dest
    } catch {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        throw
    } finally { $wc.Dispose() }
}
function Get-FileHeaderBytes([string]$Path, [int]$Count = 2) {
    $fs = [IO.File]::OpenRead($Path)
    try { $b = New-Object byte[] $Count; [void]$fs.Read($b, 0, $Count); return $b } finally { $fs.Close() }
}
function Get-FileSha256([string]$Path) { return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLower() }
function Get-SignatureInfo([string]$Path) {
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    $subj = ''; if ($s.SignerCertificate) { $subj = $s.SignerCertificate.Subject }
    return @{ Status = "$($s.Status)"; Subject = $subj }
}
function Expand-ZipSafe([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = $null; $root = Get-EnvSafe 'SystemRoot'; if ($root) { $tar = Join-PathSafe $root 'System32\tar.exe' }
    if ($tar -and (Test-Path -LiteralPath $tar)) {
        $r = Invoke-ExternalSafe $tar @('-xf', $Zip, '-C', $Dest)
        if ($r.Code -ne 0) { throw "Unpacking failed (tar exit $($r.Code))." }
    } else { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force }
}
function New-DirSafe([string]$Path) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
function Move-ItemSafe([string]$From, [string]$To) { Move-Item -LiteralPath $From -Destination $To }
function Rename-ItemSafe([string]$Path, [string]$NewName) { Rename-Item -LiteralPath $Path -NewName $NewName }
function Remove-TempSafe([string]$Path) {
    # only ever used on files/folders this script created itself (downloads, extract folders)
    try { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } } catch {}
}
function Add-UserPathSafe([string]$Dir) {
    $u = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $u) { $u = '' }
    if (@($u -split ';') -notcontains $Dir) { [Environment]::SetEnvironmentVariable('Path', ($u.TrimEnd(';') + ';' + $Dir).TrimStart(';'), 'User') }
    $env:Path = $env:Path.TrimEnd(';') + ';' + $Dir
}
function Get-NowStamp { return (Get-Date -Format 'yyyyMMddHHmmss') }

# ------------------------------------------------------------------ discovery (ported from wizard.ps1)
function Get-SavedState {
    $t = Read-TextSafe (Join-PathSafe $script:SetupData 'state.json')
    if ($t) { try { return ($t | ConvertFrom-Json) } catch {} }
    return $null
}
function Get-CsdmDir {
    $c = @()
    $st = Get-SavedState
    if ($st -and $st.CsdmDir) { $c += [string]$st.CsdmDir }
    $la = Get-EnvSafe 'LOCALAPPDATA'; $pf = Get-EnvSafe 'ProgramFiles'
    if ($la) { $c += (Join-PathSafe $la 'Programs\cs-demo-manager'); $c += (Join-PathSafe $la 'Programs\CS Demo Manager') }
    if ($pf) { $c += (Join-PathSafe $pf 'CS Demo Manager') }
    foreach ($d in $c) { if ($d -and (Test-PathSafe (Join-PathSafe $d 'csdm.cmd'))) { return $d } }
    return $null
}
function Get-CsdmVersion([string]$Dir) { return (Get-FileVersionSafe $Dir) }
function Get-SteamPath {
    $p = Get-RegValueSafe 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if ($p) { return ($p -replace '/', '\') }
    foreach ($d in ((Get-EnvSafe 'ProgramFiles(x86)') + '\Steam'), ((Get-EnvSafe 'ProgramFiles') + '\Steam')) {
        if (Test-PathSafe "$d\steam.exe") { return $d }
    }
    return $null
}
function Get-Cs2Path([string]$Steam) {
    if (-not $Steam) { return $null }
    $libs = @($Steam)
    $txt = Read-TextSafe (Join-PathSafe $Steam 'steamapps\libraryfolders.vdf')
    if ($txt) { foreach ($m in [regex]::Matches($txt, '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    foreach ($l in $libs) {
        $g = Join-PathSafe $l 'steamapps\common\Counter-Strike Global Offensive'
        if (Test-PathSafe (Join-PathSafe $g 'game\bin\win64\cs2.exe')) { return $g }
    }
    return $null
}
function Get-PyVersion([string]$Exe) {
    $r = Invoke-ExternalSafe $Exe @('-c', "import sys;print('%d.%d.%d' % sys.version_info[:3])")
    if ($r.Code -eq 0 -and $r.Out) { return (@($r.Out -split "`n")[-1]).Trim() }
    return $null
}
function Find-Python {
    foreach ($v in $script:PyOk) {
        $r = Invoke-ExternalSafe 'py.exe' @("-$v", '-c', 'import sys;print(sys.executable)')
        if ($r.Code -eq 0 -and $r.Out) { $p = (@($r.Out -split "`n")[-1]).Trim(); if (Test-PathSafe $p) { return $p } }
    }
    $la = Get-EnvSafe 'LOCALAPPDATA'; $pf = Get-EnvSafe 'ProgramFiles'
    foreach ($v in $script:PyOk) {
        $n = 'Python' + $v.Replace('.', '')
        foreach ($p in (Join-PathSafe $la "Programs\Python\$n\python.exe"), (Join-PathSafe $pf "$n\python.exe")) { if (Test-PathSafe $p) { return $p } }
    }
    foreach ($c in @(Get-CommandSafe 'python.exe')) {
        if (-not $c -or $c.Source -like '*\WindowsApps\*') { continue }   # Store placeholder only opens the Store
        $ver = Get-PyVersion $c.Source
        if ($ver -and ($script:PyOk -contains (($ver -split '\.')[0..1] -join '.'))) { return $c.Source }
    }
    return $null
}
function Get-VenvPy { return (Join-PathSafe $script:SetupData 'pyenv\Scripts\python.exe') }
function Test-HelperReady {
    if (-not (Test-PathSafe (Get-VenvPy))) { return $false }
    $r = Invoke-ExternalSafe (Get-VenvPy) @('-W', 'ignore', '-c', 'import demoparser2, zstandard, numpy, pandas')
    return ($r.Code -eq 0)
}
function Get-RecToolPaths {
    $app = Join-PathSafe (Get-EnvSafe 'USERPROFILE') '.csdm'
    $r = @{ App = $app; Hlae = (Join-PathSafe $app 'hlae\hlae.exe'); Ffmpeg = (Join-PathSafe $app 'ffmpeg\bin\ffmpeg.exe'); HlaeCustom = $false; FfmpegCustom = $false }
    $t = Read-TextSafe (Join-PathSafe $app 'settings.json')
    $s = $null; if ($t) { try { $s = $t | ConvertFrom-Json } catch {} }
    if ($s -and $s.video) {
        $h = $s.video.hlae
        if ($h -and $h.customLocationEnabled -and $h.customExecutableLocation) { $r.Hlae = Join-PathSafe (Split-Path ([string]$h.customExecutableLocation)) 'hlae.exe'; $r.HlaeCustom = $true }
        $f = $s.video.ffmpegSettings
        if ($f -and $f.customLocationEnabled -and $f.customExecutableLocation) { $r.Ffmpeg = [string]$f.customExecutableLocation; $r.FfmpegCustom = $true }
    }
    return $r
}
function Get-PsqlBin {
    $pf = Get-EnvSafe 'ProgramFiles'
    $f = @(Find-FilesSafe (Join-PathSafe $pf 'PostgreSQL\*\bin\psql.exe') | Sort-Object FullName -Descending | Select-Object -First 1)
    if ($f.Count -gt 0 -and $f[0]) { return $f[0].DirectoryName }
    return $null
}

# ------------------------------------------------------------------ checks
function New-Check([string]$Id, [string]$Label, [string]$Status, [string]$Detail, $FixId = $null) {
    return [pscustomobject]@{ id = $Id; label = $Label; status = $Status; detail = $Detail; fixId = $FixId }
}
function Get-OneCheck([string]$Id) {
    switch ($Id) {
        'csdm' {
            $d = Get-CsdmDir
            if (-not $d) { return (New-Check 'csdm' 'CS Demo Manager' 'fixable' 'Not found. It will be downloaded and installed (official release from GitHub).' 'csdm') }
            $v = Get-CsdmVersion $d
            if ($v -and $v -lt $script:MinCsdm) { return (New-Check 'csdm' 'CS Demo Manager' 'fixable' "Version $v is too old (need $($script:MinCsdm) or newer). The newest release will be installed." 'csdm') }
            $vt = '?'; if ($v) { $vt = "$v" }
            return (New-Check 'csdm' 'CS Demo Manager' 'ok' "Version $vt at $d")
        }
        'postgres' {
            $svc = @(Get-ServiceSafe 'postgresql*')
            if ($svc.Count -eq 0) { return (New-Check 'postgres' 'PostgreSQL (CSDM database)' 'manual' 'Not installed. Install PostgreSQL by following the CS Demo Manager installation guide (needs admin and a password you choose): https://cs-demo-manager.com/docs/installation') }
            if (-not @($svc | Where-Object { "$($_.Status)" -eq 'Running' })) { return (New-Check 'postgres' 'PostgreSQL (CSDM database)' 'fixable' 'Installed but not running. It will be started.' 'postgres') }
            return (New-Check 'postgres' 'PostgreSQL (CSDM database)' 'ok' 'Running')
        }
        'postgres_path' {
            if (@(Get-ServiceSafe 'postgresql*').Count -eq 0) { return (New-Check 'postgres_path' 'psql on PATH' 'manual' 'Install PostgreSQL first (see the PostgreSQL row).') }
            if (Get-CommandSafe 'psql.exe') { return (New-Check 'postgres_path' 'psql on PATH' 'ok' 'psql found') }
            $bin = Get-PsqlBin
            if ($bin) { return (New-Check 'postgres_path' 'psql on PATH' 'fixable' "psql is not on PATH (CSDM then says 'PSQL binary not found'). $bin will be added to your user PATH." 'postgres_path') }
            return (New-Check 'postgres_path' 'psql on PATH' 'manual' 'psql.exe was not found under Program Files\PostgreSQL. Reinstall PostgreSQL with the Command Line Tools option ticked.')
        }
        'steam' {
            $s = Get-SteamPath
            if ($s) { return (New-Check 'steam' 'Steam' 'ok' $s) }
            return (New-Check 'steam' 'Steam' 'manual' 'Steam not found. Install it from https://store.steampowered.com/about/')
        }
        'cs2' {
            $s = Get-SteamPath
            if (-not $s) { return (New-Check 'cs2' 'Counter-Strike 2' 'manual' 'Install Steam first, then install Counter-Strike 2 (free).') }
            $g = Get-Cs2Path $s
            if ($g) { return (New-Check 'cs2' 'Counter-Strike 2' 'ok' $g) }
            return (New-Check 'cs2' 'Counter-Strike 2' 'manual' 'Not found in your Steam libraries. Install it in Steam (free): steam://install/730')
        }
        'python' {
            $p = Find-Python
            if ($p) { return (New-Check 'python' 'Python' 'ok' "Python $(Get-PyVersion $p) at $p") }
            return (New-Check 'python' 'Python' 'fixable' 'No suitable Python (3.11-3.14) found. Python 3.12 will be installed for your Windows user only (no admin).' 'python')
        }
        'venv' {
            if (Test-HelperReady) { return (New-Check 'venv' 'Demo reader (Python packages)' 'ok' 'Ready') }
            if (-not (Find-Python)) { return (New-Check 'venv' 'Demo reader (Python packages)' 'missing' 'Needs Python first.') }
            return (New-Check 'venv' 'Demo reader (Python packages)' 'fixable' 'A private Python environment with demoparser2 will be created (2-5 minutes, needs internet).' 'venv')
        }
        'hlae' {
            $tp = Get-RecToolPaths
            if (Test-PathSafe $tp.Hlae) { return (New-Check 'hlae' 'HLAE' 'ok' $tp.Hlae) }
            if ($tp.HlaeCustom) { return (New-Check 'hlae' 'HLAE' 'manual' "CS Demo Manager is set to use your own HLAE, but it is missing: $($tp.Hlae). Fix the path in CSDM > Settings > Video.") }
            return (New-Check 'hlae' 'HLAE' 'fixable' 'Not installed. It will be downloaded from GitHub.' 'hlae')
        }
        'ffmpeg' {
            $tp = Get-RecToolPaths
            if (Test-PathSafe $tp.Ffmpeg) { return (New-Check 'ffmpeg' 'FFmpeg' 'ok' $tp.Ffmpeg) }
            if ($tp.FfmpegCustom) { return (New-Check 'ffmpeg' 'FFmpeg' 'manual' "CS Demo Manager is set to use your own FFmpeg, but it is missing: $($tp.Ffmpeg). Fix the path in CSDM > Settings > Video.") }
            return (New-Check 'ffmpeg' 'FFmpeg' 'fixable' 'Not installed. It will be downloaded from GitHub (about 185 MB).' 'ffmpeg')
        }
    }
    return $null
}
function Get-SetupCheck {
    $ids = 'csdm', 'postgres', 'postgres_path', 'steam', 'cs2', 'python', 'venv', 'hlae', 'ffmpeg'
    $out = @()
    foreach ($id in $ids) { $out += Get-OneCheck $id }
    return , $out
}

# ------------------------------------------------------------------ fixers
function Send-Progress($Cb, [int]$Pct, [string]$Msg) { if ($Cb) { try { & $Cb $Pct $Msg } catch {} } }
function New-Result([bool]$Ok, [string]$Msg) { return @{ ok = $Ok; message = $Msg } }

function Get-AssetDigest($Asset) {
    # GitHub publishes "digest": "sha256:<hex>" on release assets
    if ($Asset -and $Asset.digest -and "$($Asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1].ToLower() }
    return $null
}
function Save-Verified([string]$Url, [string]$Dest, [int64]$Size, [string]$Sha256, [string]$Kind, [string]$Name, $Cb, [int]$P0, [int]$P1) {
    # download + verify. Kind 'zip' (PK) or 'exe' (MZ). Throws and removes the file on failure.
    $onBytes = { param($len) if ($Size -gt 0) { Send-Progress $Cb ([int]($P0 + ($P1 - $P0) * [Math]::Min(1, $len / $Size))) ("Downloading {0}: {1:N0} / {2:N0} MB" -f $Name, ($len / 1MB), ($Size / 1MB)) } }.GetNewClosure()
    Send-Progress $Cb $P0 "Downloading $Name..."
    Invoke-Download $Url $Dest $onBytes
    try {
        $h = Get-FileHeaderBytes $Dest 2
        if ($Kind -eq 'zip' -and -not ($h[0] -eq 0x50 -and $h[1] -eq 0x4B)) { throw 'The download is not a zip file (a web page came back instead). Try again in a moment.' }
        if ($Kind -eq 'exe' -and -not ($h[0] -eq 0x4D -and $h[1] -eq 0x5A)) { throw 'The download is not a Windows program (a web page came back instead). Try again in a moment.' }
        if ($Sha256) {
            $got = Get-FileSha256 $Dest
            if ($got -ne $Sha256) { throw "The download is damaged or was changed (SHA256 mismatch for $Name)." }
        }
    } catch { Remove-TempSafe $Dest; throw }
}
function Install-ZipTool([string]$Kind, $Cb) {
    $tp = Get-RecToolPaths
    New-DirSafe $script:SetupData
    New-DirSafe $tp.App
    if ($Kind -eq 'hlae') {
        $rel = @(Get-JsonSafe 'https://api.github.com/repos/advancedfx/advancedfx/releases') | Where-Object { -not $_.prerelease } | Select-Object -First 1
        $a = @($rel.assets | Where-Object { $_.name -match '^hlae_[\d_]+\.zip$' }) + @($rel.assets | Where-Object { $_.name -match '\.zip$' })
        if (-not $a -or -not $a[0]) { throw 'No HLAE download found on GitHub.' }
        $asset = $a[0]; $name = "HLAE $($rel.tag_name)"; $dest = Join-PathSafe $tp.App 'hlae'
    } else {
        $rel = Get-JsonSafe 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest'
        $asset = $null; $bestV = [version]'0.0'
        foreach ($x in $rel.assets) {
            $m = [regex]::Match($x.name, '^ffmpeg-n(\d+\.\d+(?:\.\d+)?)-latest-win64-gpl-[\d.]+\.zip$')
            if ($m.Success -and [version]$m.Groups[1].Value -gt $bestV) { $asset = $x; $bestV = [version]$m.Groups[1].Value }
        }
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-gpl.zip' } | Select-Object -First 1 }
        if (-not $asset) { throw 'No FFmpeg download found on GitHub.' }
        $name = "FFmpeg $($asset.name)"; $dest = Join-PathSafe $tp.App 'ffmpeg'
    }
    $zip = Join-PathSafe $script:SetupData "dl_$Kind.zip"
    $tmp = Join-PathSafe $tp.App "_extract_$Kind"
    try {
        Save-Verified $asset.browser_download_url $zip ([int64]$asset.size) (Get-AssetDigest $asset) 'zip' $name $Cb 2 80
        Send-Progress $Cb 85 "Unpacking $name..."
        Remove-TempSafe $tmp
        Expand-ZipSafe $zip $tmp
        if ($Kind -eq 'hlae') {
            $exe = @(Find-FilesInTree $tmp 'hlae.exe') | Select-Object -First 1
            if (-not $exe) { throw 'hlae.exe was not found in the download.' }
            $src = $exe.DirectoryName
        } else {
            $exe = @(Find-FilesInTree $tmp 'ffmpeg.exe') | Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq 'bin' } | Select-Object -First 1
            if (-not $exe) { throw 'bin\ffmpeg.exe was not found in the download.' }
            $src = Split-Path -Parent $exe.DirectoryName
        }
        $moved = $null
        if (Test-PathSafe $dest) { $moved = (Split-Path -Leaf $dest) + '_old_' + (Get-NowStamp); Rename-ItemSafe $dest $moved }   # never delete: rename
        try { Move-ItemSafe $src $dest }
        catch { if ($moved) { Rename-ItemSafe (Join-PathSafe (Split-Path -Parent $dest) $moved) (Split-Path -Leaf $dest) }; throw }
    } finally { Remove-TempSafe $zip; Remove-TempSafe $tmp }
    Send-Progress $Cb 100 "$name installed."
}

function Fix-Csdm($Cb) {
    $rel = Get-JsonSafe 'https://api.github.com/repos/akiver/cs-demo-manager/releases/latest'
    $a = @($rel.assets | Where-Object { $_.name -match '\.exe$' -and $_.name -notmatch 'blockmap' })
    $pick = $a | Where-Object { $_.name -match 'setup|install' } | Select-Object -First 1
    if (-not $pick) { $pick = $a | Select-Object -First 1 }
    if (-not $pick) { throw "No installer found in the latest release. Download it from $($script:CsdmPage)" }
    New-DirSafe $script:SetupData
    $exe = Join-PathSafe $script:SetupData 'csdm-setup.exe'
    try {
        Save-Verified $pick.browser_download_url $exe ([int64]$pick.size) (Get-AssetDigest $pick) 'exe' "CS Demo Manager $($rel.tag_name)" $Cb 2 70
        Send-Progress $Cb 75 'Installing CS Demo Manager (silent)...'
        $r = Invoke-ExternalSafe $exe @('/S')
        if ($r.Code -ne 0) { throw "The CS Demo Manager installer ended with code $($r.Code). Download it yourself: $($script:CsdmPage)" }
    } finally { Remove-TempSafe $exe }
    if (-not (Get-CsdmDir)) { throw "Installed, but csdm.cmd was not found. If you chose a custom folder, open CS Demo Manager once. Download page: $($script:CsdmPage)" }
    Send-Progress $Cb 100 'CS Demo Manager installed.'
}
function Fix-Python($Cb) {
    if (Find-Python) { return }
    if (Get-CommandSafe 'winget.exe') {
        Send-Progress $Cb 10 'Installing Python 3.12 with winget...'
        [void](Invoke-ExternalSafe 'winget.exe' @('install', '-e', '--id', 'Python.Python.3.12', '--scope', 'user', '--accept-package-agreements', '--accept-source-agreements', '--silent'))
        if (Find-Python) { Send-Progress $Cb 100 'Python installed.'; return }
        Send-Progress $Cb 30 'winget did not finish. Using the official installer from python.org...'
    }
    New-DirSafe $script:SetupData
    $exe = Join-PathSafe $script:SetupData 'python-3.12.10-amd64.exe'
    try {
        Save-Verified $script:PyUrl $exe 26964224 $null 'exe' 'Python 3.12.10' $Cb 35 80
        $sig = Get-SignatureInfo $exe
        if ($sig.Status -ne 'Valid' -or $sig.Subject -notmatch 'Python Software Foundation') { throw "The downloaded installer is not validly signed by the Python Software Foundation (status: $($sig.Status)). It was removed." }
        Send-Progress $Cb 85 'Installing Python 3.12.10 (about 1-2 minutes)...'
        $r = Invoke-ExternalSafe $exe @('/quiet', 'InstallAllUsers=0', 'InstallLauncherAllUsers=0', 'Include_launcher=1', 'PrependPath=1', 'Include_test=0', 'Include_doc=0', 'Shortcuts=0')
        if ($r.Code -ne 0) { throw "The Python installer ended with code $($r.Code)." }
    } finally { Remove-TempSafe $exe }
    if (-not (Find-Python)) { throw "Python was installed but could not be found yet. Restart this tool. Manual download: $($script:PyPage)" }
    Send-Progress $Cb 100 'Python installed.'
}
function Fix-Venv($Cb) {
    $py = Find-Python
    if (-not $py) { throw 'Install Python first.' }
    $venv = Join-PathSafe $script:SetupData 'pyenv'
    New-DirSafe $script:SetupData
    if (-not (Test-PathSafe (Get-VenvPy))) {
        if (Test-PathSafe $venv) { Rename-ItemSafe $venv ('pyenv_old_' + (Get-NowStamp)) }   # broken env: keep, do not delete
        Send-Progress $Cb 10 'Creating a private Python environment...'
        $r = Invoke-ExternalSafe $py @('-m', 'venv', $venv)
        if ($r.Code -ne 0) { throw "Creating the Python environment failed: $($r.Out)" }
    }
    Send-Progress $Cb 30 'Installing demoparser2 and friends (2-5 minutes)...'
    $r = Invoke-ExternalSafe (Get-VenvPy) @('-m', 'pip', 'install', '--disable-pip-version-check', 'demoparser2', 'zstandard', 'numpy', 'pandas')
    if ($r.Code -ne 0 -or -not (Test-HelperReady)) { throw "Installing the demo reader failed (code $($r.Code)). Check your internet connection and try again." }
    Send-Progress $Cb 100 'Demo reader ready.'
}
function Fix-Postgres($Cb) {
    $svc = @(Get-ServiceSafe 'postgresql*')
    if ($svc.Count -eq 0) { throw 'PostgreSQL is not installed. See https://cs-demo-manager.com/docs/installation' }
    foreach ($s in $svc) {
        if ("$($s.Status)" -eq 'Running') { continue }
        Send-Progress $Cb 30 "Starting $($s.Name)..."
        if (-not (Start-ServiceSafe $s.Name)) {
            Send-Progress $Cb 50 'Windows needs your permission to start the service...'
            [void](Start-ElevatedSafe ("Start-Service -Name '" + ($s.Name -replace "'", "''") + "'"))
        }
    }
    if (-not @(Get-ServiceSafe 'postgresql*' | Where-Object { "$($_.Status)" -eq 'Running' })) { throw 'The PostgreSQL service could not be started. Restart the PC or start it in Services.' }
    Send-Progress $Cb 100 'PostgreSQL is running.'
}
function Fix-PostgresPath($Cb) {
    $bin = Get-PsqlBin
    if (-not $bin) { throw 'psql.exe was not found under Program Files\PostgreSQL.' }
    Send-Progress $Cb 50 "Adding $bin to your user PATH..."
    Add-UserPathSafe $bin
    Send-Progress $Cb 100 'PATH updated. Restart CS Demo Manager if it is open.'
}

function Invoke-SetupFix {
    param([string]$Id, [scriptblock]$OnProgress)
    try {
        $c = Get-OneCheck $Id
        if (-not $c) { return (New-Result $false "Unknown item: $Id") }
        if ($c.status -eq 'ok') { return (New-Result $true "$($c.label) is already OK.") }
        if ($c.status -ne 'fixable') { return (New-Result $false $c.detail) }
        Send-Progress $OnProgress 0 "Fixing $($c.label)..."
        switch ($Id) {
            'csdm' { Fix-Csdm $OnProgress }
            'postgres' { Fix-Postgres $OnProgress }
            'postgres_path' { Fix-PostgresPath $OnProgress }
            'python' { Fix-Python $OnProgress }
            'venv' { Fix-Venv $OnProgress }
            'hlae' { Install-ZipTool 'hlae' $OnProgress }
            'ffmpeg' { Install-ZipTool 'ffmpeg' $OnProgress }
        }
        $after = Get-OneCheck $Id
        if ($after.status -eq 'ok') { return (New-Result $true "$($c.label) is OK now.") }
        return (New-Result $false "$($c.label) is still not OK: $($after.detail)")
    } catch {
        return (New-Result $false ("$($_.Exception.Message)" -replace '[\r\n]+', ' '))
    }
}
function Invoke-SetupAll {
    param([scriptblock]$OnProgress)
    $n = $script:FixOrder.Count; $i = 0
    foreach ($id in $script:FixOrder) {
        $c = Get-OneCheck $id     # re-check each item: earlier fixes can unlock later ones
        if ($c -and $c.status -eq 'fixable') {
            $base = [int](100 * $i / $n); $span = [int](100 / $n)
            $cb = { param($p, $m) Send-Progress $OnProgress ($base + [int]($p * $span / 100)) $m }.GetNewClosure()
            $r = Invoke-SetupFix -Id $id -OnProgress $cb
            if (-not $r.ok) { Send-Progress $OnProgress $base ("Could not fix {0}: {1}" -f $c.label, $r.message) }
        }
        $i++
    }
    Send-Progress $OnProgress 100 'Done.'
    return (Get-SetupCheck)
}

# ------------------------------------------------------------------ CLI (only when run directly with a switch)
if ($Check -or $Fix -or $All) {
    $ErrorActionPreference = 'Stop'
    $cli = { param($p, $m) [Console]::Error.WriteLine(("[{0,3}%] {1}" -f $p, $m)) }
    if ($Check) { $res = Get-SetupCheck }
    elseif ($Fix) { $res = Invoke-SetupFix -Id $Fix -OnProgress $cli }
    else { $res = Invoke-SetupAll -OnProgress $cli }
    ConvertTo-Json -InputObject $res -Depth 5
}
