# CS2 Recorder - guided, automatic CS2 demo recording with CS Demo Manager + HLAE.
# Started by START.bat. Windows PowerShell 5.1, no extra installs needed for the window itself.
# All text in this file is plain ASCII on purpose.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Tool = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Base = Split-Path -Parent $script:Tool
$script:Data = Join-Path $script:Base 'data'
New-Item -ItemType Directory -Force -Path $script:Data | Out-Null
Get-ChildItem $script:Base -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

$script:LogFile = Join-Path $script:Data 'wizard.log'
function Log([string]$m) { try { Add-Content -Path $script:LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) } catch {} }
Log '--- wizard started ---'

$MIN_CSDM = [version]'3.20.1'
$TICK = 64
$UTF8 = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------------ state
$script:StateFile = Join-Path $script:Data 'state.json'
$script:S = @{
    OutDir = (Join-Path $script:Base 'recordings'); Width = 1920; Height = 1080; Fps = 60
    Layers = @('clean', 'hud', 'depth', 'players', 'viewModel', 'particlesBlack')
    CamOn = $true; CamFps = 120; Fov = 50; CamDist = 110
    CamLayers = @('clean', 'players', 'depth', 'particlesBlack')
    Before = 4; After = 2; Join = 8; LastPlayer = ''
}
if (Test-Path $script:StateFile) {
    try {
        $saved = Get-Content $script:StateFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $script:S[$p.Name] = $p.Value }
    } catch { Log "state load failed: $_" }
}
# runtime-only values (never saved)
$script:R = @{ CanNext = $false; Players = @(); Kills = @(); Deaths = @(); Clips = @(); Py = $null }

function Save-State {
    $keep = 'OutDir', 'Width', 'Height', 'Fps', 'Layers', 'CamOn', 'CamFps', 'Fov', 'CamDist', 'CamLayers',
            'Before', 'After', 'Join', 'LastPlayer', 'AccountId', 'AccountKind', 'GraphicsAt', 'CsdmDir'
    $o = [ordered]@{}
    foreach ($k in $keep) { if ($script:S.ContainsKey($k)) { $o[$k] = $script:S[$k] } }
    try { [IO.File]::WriteAllText($script:StateFile, ($o | ConvertTo-Json -Depth 5), $UTF8) } catch { Log "state save failed: $_" }
}

# ------------------------------------------------------------------ colours / fonts
$C_BG = [Drawing.Color]::FromArgb(18, 22, 20)
$C_PANEL = [Drawing.Color]::FromArgb(26, 32, 29)
$C_TEXT = [Drawing.Color]::FromArgb(214, 226, 216)
$C_DIM = [Drawing.Color]::FromArgb(140, 158, 145)
$C_ACC = [Drawing.Color]::FromArgb(61, 220, 132)
$C_WARN = [Drawing.Color]::FromArgb(255, 196, 61)
$C_BAD = [Drawing.Color]::FromArgb(255, 99, 99)
$F_BODY = New-Object Drawing.Font('Segoe UI', 10)
$F_BOLD = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$F_TITLE = New-Object Drawing.Font('Segoe UI Semibold', 16)
$F_MONO = New-Object Drawing.Font('Consolas', 9.5)

# ------------------------------------------------------------------ window
$form = New-Object Windows.Forms.Form
$form.Text = 'CS2 Recorder'
$form.ClientSize = New-Object Drawing.Size(1040, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = $F_BODY
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
try { $form.Icon = New-Object Drawing.Icon((Join-Path $script:Tool 'icon.ico')) } catch {}

$side = New-Object Windows.Forms.Panel
$side.SetBounds(0, 0, 220, 700); $side.BackColor = $C_PANEL
$form.Controls.Add($side)
$brand = New-Object Windows.Forms.Label
$brand.Text = "CS2 RECORDER"; $brand.Font = New-Object Drawing.Font('Consolas', 15, [Drawing.FontStyle]::Bold)
$brand.ForeColor = $C_ACC; $brand.SetBounds(18, 18, 200, 30)
$side.Controls.Add($brand)

$script:Content = New-Object Windows.Forms.Panel
$script:Content.SetBounds(240, 10, 790, 620); $script:Content.AutoScroll = $true
$form.Controls.Add($script:Content)

function New-NavButton($text, $x) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, 645, 140, 40)
    $b.FlatStyle = 'Flat'; $b.BackColor = $C_PANEL; $b.ForeColor = $C_TEXT
    $b.FlatAppearance.BorderColor = $C_DIM
    $form.Controls.Add($b); return $b
}
$btnBack = New-NavButton '< Back' 740
$btnNext = New-NavButton 'Next >' 890
$btnNext.Font = $F_BOLD
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.SetBounds(240, 655, 490, 24); $lblStatus.ForeColor = $C_DIM
$form.Controls.Add($lblStatus)

# ------------------------------------------------------------------ layout helpers (top-to-bottom cursor)
$script:Y = 0
function Reset-Content { $script:Content.Controls.Clear(); $script:Content.AutoScrollPosition = New-Object Drawing.Point(0, 0); $script:Y = 0 }
function Add-Ctl($c, [int]$h, [int]$x = 0, [int]$w = 760, [switch]$Same) {
    $c.SetBounds($x, $script:Y, $w, $h)
    $script:Content.Controls.Add($c)
    if (-not $Same) { $script:Y += $h + 8 }
    return $c
}
function Add-Title([string]$t) {
    $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.Font = $F_TITLE; $l.ForeColor = $C_ACC
    [void](Add-Ctl $l 38); return $l
}
function Measure-H([string]$t, $font, [int]$w) {
    $sz = [Windows.Forms.TextRenderer]::MeasureText($t, $font, (New-Object Drawing.Size($w, 10000)), [Windows.Forms.TextFormatFlags]::WordBreak)
    return [Math]::Max(22, $sz.Height + 6)
}
function Add-Text([string]$t, $color = $null, [switch]$Bold, [int]$x = 0, [int]$w = 760) {
    $l = New-Object Windows.Forms.Label; $l.Text = $t
    if ($Bold) { $l.Font = $F_BOLD }
    if ($color) { $l.ForeColor = $color }
    $h = Measure-H $t $l.Font $w
    return (Add-Ctl $l $h $x $w)
}
function Add-Box([string]$t, $color) {
    $p = New-Object Windows.Forms.Label; $p.Text = $t; $p.ForeColor = $color
    $p.BorderStyle = 'FixedSingle'; $p.Padding = New-Object Windows.Forms.Padding(8)
    $h = (Measure-H $t $F_BODY 730) + 16
    return (Add-Ctl $p $h)
}
function Add-Button([string]$t, [scriptblock]$onClick, [int]$x = 0, [int]$w = 220, [switch]$Same) {
    $b = New-Object Windows.Forms.Button; $b.Text = $t; $b.FlatStyle = 'Flat'
    $b.BackColor = $C_PANEL; $b.ForeColor = $C_TEXT; $b.FlatAppearance.BorderColor = $C_ACC
    $b.Add_Click($onClick)
    return (Add-Ctl $b 34 $x $w -Same:$Same)
}
function Add-Check([string]$t, [bool]$checked, [scriptblock]$onChange, [int]$x = 0, [int]$w = 760, [switch]$Same) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text = $t; $c.Checked = $checked
    if ($onChange) { $c.Add_CheckedChanged($onChange) }
    return (Add-Ctl $c 26 $x $w -Same:$Same)
}
function Add-Log([int]$h = 160) {
    $t = New-Object Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'
    $t.Font = $F_MONO; $t.BackColor = [Drawing.Color]::Black; $t.ForeColor = $C_ACC
    return (Add-Ctl $t $h)
}
function Show-Error([string]$m) {
    Log "ERROR: $m"
    [void][Windows.Forms.MessageBox]::Show($form, $m, 'CS2 Recorder', 'OK', 'Warning')
}
function Ask-YesNo([string]$m) {
    return ([Windows.Forms.MessageBox]::Show($form, $m, 'CS2 Recorder', 'YesNo', 'Question') -eq 'Yes')
}
function Copy-Text([string]$t) { [Windows.Forms.Clipboard]::SetText($t); $lblStatus.Text = "Copied to clipboard: $t" }

# ------------------------------------------------------------------ background processes (window never freezes)
$script:Jobs = New-Object Collections.ArrayList
$script:OnTick = $null
function Start-Bg([string]$command, [scriptblock]$onDone, $ctx = $null, [string]$logFile = '') {
    # $command is a complete, already quoted command line, e.g. "C:\py.exe" "C:\x.py" info "C:\d.dem"
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $script:Data "job_$id.out"; $err = Join-Path $script:Data "job_$id.err"
    if ($logFile) { $redir = "> `"$logFile`" 2>&1"; $out = $logFile; $err = '' } else { $redir = "> `"$out`" 2> `"$err`"" }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = "/s /c `"$command $redir`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    Log "RUN: $command"
    $p = [Diagnostics.Process]::Start($psi)
    $job = @{ P = $p; Out = $out; Err = $err; OnDone = $onDone; Ctx = $ctx; Cmd = $command; Start = (Get-Date) }
    [void]$script:Jobs.Add($job)
    return $job
}
function Read-All([string]$f) {
    if (-not $f -or -not (Test-Path $f)) { return '' }
    try {
        $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); return $t
    } catch { return '' }
}
function Stop-AllJobs {
    foreach ($j in @($script:Jobs)) {
        try { & taskkill.exe /PID $j.P.Id /T /F 2>&1 | Out-Null } catch {}
    }
    $script:Jobs.Clear()
}
$script:Spin = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        foreach ($j in @($script:Jobs)) {
            if ($j.P.HasExited) {
                $script:Jobs.Remove($j)
                $o = Read-All $j.Out; $e = Read-All $j.Err
                Log ("DONE (exit {0}): {1}`r`n{2}" -f $j.P.ExitCode, $j.Cmd, ($e -replace '(?s)^(.{0,3000}).*', '$1'))
                & $j.OnDone $o $e $j.P.ExitCode $j.Ctx
            }
        }
        if ($script:Jobs.Count -gt 0) {
            $script:Spin = ($script:Spin + 1) % 4
            $lblStatus.Text = 'Working' + ('.' * ($script:Spin + 1))
            $btnNext.Enabled = $false; $btnBack.Enabled = $false
        } elseif ($lblStatus.Text -like 'Working*') { $lblStatus.Text = ''; Update-Nav }
        if ($script:OnTick) { & $script:OnTick }
    } catch { Show-Error ("Unexpected error: " + $_.Exception.Message) }
})

function Parse-Json([string]$o, [string]$e) {
    $line = ($o -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { return @{ ok = $false; error = ("No answer from the helper.`r`n" + $e.Trim()) } }
    try { return ($line | ConvertFrom-Json) } catch { return @{ ok = $false; error = "Bad answer: $line" } }
}
function Q([string]$s) { return '"' + $s + '"' }   # quote for command lines
function Helper([string]$argStr) { return (Q $script:R.Py) + ' ' + (Q (Join-Path $script:Tool 'cs2tool.py')) + ' ' + $argStr }

# ------------------------------------------------------------------ system checks
function Get-CsdmDir {
    $c = @()
    if ($script:S.CsdmDir) { $c += $script:S.CsdmDir }
    $c += (Join-Path $env:LOCALAPPDATA 'Programs\cs-demo-manager')
    $c += (Join-Path $env:LOCALAPPDATA 'Programs\CS Demo Manager')
    $c += (Join-Path $env:ProgramFiles 'CS Demo Manager')
    foreach ($d in $c) { if ($d -and (Test-Path (Join-Path $d 'csdm.cmd'))) { return $d } }
    return $null
}
function Get-CsdmVersion([string]$dir) {
    $exe = Get-ChildItem $dir -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'demo' } | Select-Object -First 1
    if (-not $exe) { return $null }
    $v = $exe.VersionInfo.ProductVersion
    if (-not $v) { $v = $exe.VersionInfo.FileVersion }
    try { return [version](($v -split '[^0-9.]')[0]) } catch { return $null }
}
function Get-SteamPath {
    try { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath; if ($p) { return ($p -replace '/', '\') } } catch {}
    foreach ($d in "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam") { if (Test-Path "$d\steam.exe") { return $d } }
    return $null
}
function Get-Cs2Path([string]$steam) {
    if (-not $steam) { return $null }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    foreach ($l in $libs) {
        $g = Join-Path $l 'steamapps\common\Counter-Strike Global Offensive'
        if (Test-Path (Join-Path $g 'game\bin\win64\cs2.exe')) { return $g }
    }
    return $null
}
function Get-SteamAccounts([string]$steam) {
    $f = Join-Path $steam 'config\loginusers.vdf'
    $list = @()
    if (-not (Test-Path $f)) { return $list }
    $txt = Get-Content $f -Raw
    foreach ($m in [regex]::Matches($txt, '"(\d{17})"\s*\{([^}]*)\}')) {
        $b = $m.Groups[2].Value
        $get = { param($k) $x = [regex]::Match($b, '(?i)"' + $k + '"\s*"([^"]*)"'); if ($x.Success) { $x.Groups[1].Value } else { '' } }
        $list += [pscustomobject]@{
            Id = $m.Groups[1].Value; Account = (& $get 'AccountName'); Persona = (& $get 'PersonaName')
            Recent = ((& $get 'MostRecent') -eq '1')
        }
    }
    return $list
}
function Get-VideoCfgPath([string]$steam, [string]$id64) {
    if (-not $id64) { return $null }
    $acc = [int64]$id64 - 76561197960265728
    return (Join-Path $steam "userdata\$acc\730\local\cfg\cs2_video.txt")
}
$PY_OK = @('3.12', '3.13', '3.11', '3.14')   # versions with ready-made demoparser2 builds; 3.12 preferred
function Get-PyVersion([string]$exe) {
    $ErrorActionPreference = 'Continue'
    try { $v = & $exe -c "import sys;print('%d.%d.%d' % sys.version_info[:3])" 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return (@($v)[-1]).Trim() } } catch {}
    return $null
}
function Find-Python {
    $ErrorActionPreference = 'Continue'   # stderr from py.exe must not count as a crash
    $found = @()
    foreach ($v in $PY_OK) {
        try {
            $r = & py.exe "-$v" -c 'import sys;print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $r) { $p = (@($r)[-1]).Trim(); if (Test-Path $p) { return $p } }
        } catch {}
    }
    foreach ($v in $PY_OK) {
        $n = 'Python' + $v.Replace('.', '')
        foreach ($p in (Join-Path $env:LOCALAPPDATA "Programs\Python\$n\python.exe"), (Join-Path $env:ProgramFiles "$n\python.exe")) { if (Test-Path $p) { return $p } }
    }
    # python.exe on PATH (skip the Microsoft Store placeholder in WindowsApps, it only opens the Store)
    foreach ($c in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($c.Source -like '*\WindowsApps\*') { continue }
        $ver = Get-PyVersion $c.Source
        if ($ver -and ($PY_OK -contains (($ver -split '\.')[0..1] -join '.'))) { return $c.Source }
    }
    return $null
}
$script:VenvPy = Join-Path $script:Data 'pyenv\Scripts\python.exe'
function Test-HelperReady {
    if (-not (Test-Path $script:VenvPy)) { return $false }
    $ErrorActionPreference = 'Continue'   # harmless warnings on stderr must not count as failure
    try { & $script:VenvPy -W ignore -c 'import demoparser2, zstandard, numpy, pandas' 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# ------------------------------------------------------------------ layers
$LAYERS = @(
    @{ Key = 'clean'; Name = 'Clean picture (no HUD)'; Kind = 'h264'; Cam = $true; Mb = 4
       Desc = 'The game image without killfeed or HUD. The main base for editing.' },
    @{ Key = 'hud'; Name = 'HUD / killfeed only'; Kind = 'prores'; Cam = $true; Mb = 12
       Desc = 'Killfeed on a transparent background (.mov). Lay it on top of your effects.' },
    @{ Key = 'depth'; Name = 'Depth'; Kind = 'depth'; Cam = $true; Mb = 10
       Desc = 'Grey distance image for depth of field / fog. It looks almost black: that is normal, it gets brightened in editing.' },
    @{ Key = 'depthNoEnts'; Name = 'Depth without players'; Kind = 'depth'; Cam = $true; Mb = 10
       Desc = 'Same as Depth but players are left out.' },
    @{ Key = 'players'; Name = 'Players cut-out (matte)'; Kind = 'prores'; Cam = $true; Mb = 15
       Desc = 'Only the players, with transparency. For outlines, glow, or keeping players sharp.' },
    @{ Key = 'viewModel'; Name = 'Weapon + hands cut-out'; Kind = 'prores'; Cam = $false; Mb = 20
       Desc = 'Only your weapon and hands, with transparency. For weapon glow. First-person only.' },
    @{ Key = 'world'; Name = 'World only (map, no players)'; Kind = 'h264'; Cam = $true; Mb = 4
       Desc = 'The map without players.' },
    @{ Key = 'particlesBlack'; Name = 'Particles on black'; Kind = 'h264'; Cam = $true; Mb = 2
       Desc = 'Muzzle flash, blood, smoke only, on black. For making effects stronger.' },
    @{ Key = 'particlesWhite'; Name = 'Particles on white'; Kind = 'h264'; Cam = $true; Mb = 2
       Desc = 'Same particles on white (helps cutting them out).' }
)
function Get-Layer([string]$k) { foreach ($l in $LAYERS) { if ($l.Key -eq $k) { return $l } }; return $null }

# ------------------------------------------------------------------ CFG text (HLAE mirv_streams)
function New-LayerCfg([string]$prefix, [string]$key, [string]$dirFwd) {
    $l = Get-Layer $key
    $st = $prefix + $key            # stream name, unique per clip and pass, e.g. p1clean
    $pr = $prefix + 's' + $key      # settings preset name
    $ext = 'mp4'; if ($l.Kind -ne 'h264') { $ext = 'mov' }
    $file = "$dirFwd/$key.$ext"
    $lines = New-Object Collections.Generic.List[string]
    switch ($l.Kind) {
        'h264' { $lines.Add("mirv_streams settings add ffmpeg $pr `"-c:v libx264 -preset veryfast -crf 14 -pix_fmt yuv420p -y {QUOTE}$file{QUOTE}`"") }
        'prores' { $lines.Add("mirv_streams settings add ffmpeg $pr `"-c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le -y {QUOTE}$file{QUOTE}`"") }
        'depth' {
            $lines.Add("mirv_streams settings add ffmpegEx $pr `"`"")
            $lines.Add(('mirv_streams settings edit @P@ options "{QUOTE}{FFMPEG_PATH}{QUOTE} -f rawvideo -pixel_format {PIXEL_FORMAT} -loglevel repeat+level+warning -framerate {FRAMERATE} -video_size {WIDTH}x{HEIGHT} -i pipe:0"').Replace('@P@', $pr))
            $lines.Add(('mirv_streams settings edit @P@ options+ " -filter_complex {QUOTE}[0:v]setsar=sar=1/1,geq=lum_expr=' + "'p(X,Y)/4096'" + '[out]{QUOTE}"').Replace('@P@', $pr))
            $lines.Add(('mirv_streams settings edit @P@ options+ " -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le -map {QUOTE}[out]{QUOTE} -y {QUOTE}@F@{QUOTE}"').Replace('@P@', $pr).Replace('@F@', $file))
        }
    }
    switch ($key) {
        'clean' { $lines.Add("mirv_streams add normal $st"); $lines.Add("mirv_streams edit $st capture beforeUi") }
        'hud' { $lines.Add("mirv_streams add normal $st"); $lines.Add("mirv_streams edit $st captureType rgba"); $lines.Add("mirv_streams edit $st clearBeforeUI 0.5 0.5 0.5 0") }
        { $_ -in 'depth', 'depthNoEnts' } {
            $lines.Add("mirv_streams add normal $st"); $lines.Add("mirv_streams edit $st capture beforeUi")
            $lines.Add("mirv_streams edit $st captureType depthF"); $lines.Add("mirv_streams edit $st depthChannels gray")
            $lines.Add("mirv_streams edit $st depthMode pyramidalLinear"); $lines.Add("mirv_streams edit $st depthVal 0")
            $lines.Add("mirv_streams edit $st depthValMax 4096")
            if ($key -eq 'depthNoEnts') {
                $lines.Add("mirv_streams edit $st beforeCommands add sc_setclassflags SkinnedObject 8")
                $lines.Add("mirv_streams edit $st afterCommands add sc_setclassflags SkinnedObject 0")
            }
        }
        'world' { $lines.Add("mirv_streams add world $st") }
        'players' { $lines.Add("mirv_streams add playersMatte $st") }
        'viewModel' { $lines.Add("mirv_streams add viewModelMatte $st") }
        'particlesBlack' { $lines.Add("mirv_streams add particlesBlack $st") }
        'particlesWhite' { $lines.Add("mirv_streams add particlesWhite $st") }
    }
    $lines.Add("mirv_streams edit $st settings $pr")
    return $lines
}
function Get-ExpectedFile([string]$dir, [string]$key) {
    $l = Get-Layer $key; $ext = 'mp4'; if ($l.Kind -ne 'h264') { $ext = 'mov' }
    return (Join-Path $dir "$key.$ext")
}
function Test-SafePath([string]$p) {
    if ($p -match '[^\x20-\x7E]') { return 'The folder path has special letters (like a, o with dots, or accents). Recording tools can break on them. Pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p -match '[#%"''&^]') { return 'The folder path contains one of these characters: # % " '' & ^ - please pick a simpler path like C:\cs2-recorder\recordings.' }
    if ($p -match '//') { return 'The folder path contains //. Please pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p.Length -gt 120) { return 'The folder path is very long. Please pick a shorter one like C:\cs2-recorder\recordings.' }
    return $null
}

# ------------------------------------------------------------------ clips from chosen kills
function Build-Clips($kills) {
    $sel = @($kills | Sort-Object tick)
    $clips = @()
    $cur = $null
    foreach ($k in $sel) {
        $s = [int]($k.tick - $script:S.Before * $TICK); $e = [int]($k.tick + $script:S.After * $TICK)
        if ($cur -and $k.round -eq $cur.Round -and ($k.tick - $cur.Kills[-1].tick) -le $script:S.Join * $TICK) {
            $cur.Kills += $k; $cur.End = $e
        } elseif ($cur -and $s -le $cur.End + 128) {
            $cur.Kills += $k; $cur.End = $e   # padded windows would overlap -> one clip
        } else {
            if ($cur) { $clips += $cur }
            $cur = @{ Round = $k.round; Kills = @($k); Start = [Math]::Max(192, $s); End = $e }
        }
    }
    if ($cur) { $clips += $cur }
    $i = 0
    foreach ($c in $clips) {
        $i++
        $c.N = $i
        $c.Name = 'clip{0:D2}_r{1}_{2}k' -f $i, $c.Round, $c.Kills.Count
        $last = $c.Kills[-1].tick
        # camera pass: 1 s earlier (the camera needs a moment to settle), stop before the player dies
        $c.CamStart = [Math]::Max(192, $c.Start - $TICK)
        $c.CamEnd = $c.End
        foreach ($d in $script:R.Deaths) { if ($d.tick -gt $last -and $d.tick -lt $c.CamEnd + 8) { $c.CamEnd = [Math]::Min($c.CamEnd, $d.tick - 8) } }
        if ($c.CamEnd -le $last) { $c.CamEnd = $last + 8 }
    }
    return , $clips
}

# ------------------------------------------------------------------ pages
$script:Page = 0
$script:Pages = @()
$script:StepLabels = @()
function Set-CanNext([bool]$v) { $script:R.CanNext = $v; Update-Nav }
function Update-Nav {
    $busy = $script:Jobs.Count -gt 0
    $btnBack.Enabled = (-not $busy) -and $script:Page -gt 0 -and $script:Page -lt ($script:Pages.Count - 1) -and -not $script:R.Recording
    $btnNext.Enabled = (-not $busy) -and $script:R.CanNext
    if ($script:Page -eq $script:Pages.Count - 1) { $btnNext.Text = 'Close' } else { $btnNext.Text = 'Next >' }
}
function Show-Page([int]$i) {
    $script:Page = $i; $script:OnTick = $null
    Reset-Content
    for ($k = 0; $k -lt $script:StepLabels.Count; $k++) {
        $l = $script:StepLabels[$k]
        if ($k -eq $i) { $l.ForeColor = $C_ACC; $l.Font = $F_BOLD } elseif ($k -lt $i) { $l.ForeColor = $C_TEXT; $l.Font = $F_BODY } else { $l.ForeColor = $C_DIM; $l.Font = $F_BODY }
    }
    $script:R.CanNext = $false
    try { & $script:Pages[$i].Build } catch { Show-Error ("Could not show this step: " + $_.Exception.Message + "`r`n" + $_.ScriptStackTrace) }
    Update-Nav
}

# ---------- 0 welcome
$script:Pages += @{ Title = 'Welcome'; Build = {
    Add-Title 'Record CS2 frags - step by step' | Out-Null
    Add-Text ("This tool records the frags you choose from a CS2 demo, fully automatically.`r`n`r`n" +
        "You get, for every frag:`r`n" +
        "  - the normal first-person video with killfeed and game sound`r`n" +
        "  - separate layers for editing (clean picture, killfeed only, depth, cut-outs of players and weapon, particles)`r`n" +
        "  - optionally a cinematic third-person camera shot, computed from the demo (no manual flying)`r`n`r`n" +
        "What happens:`r`n" +
        "  1. The tool checks your PC has everything.`r`n" +
        "  2. You confirm your Steam account and graphics settings.`r`n" +
        "  3. You pick a demo, a player and the kills.`r`n" +
        "  4. You choose which layers you want.`r`n" +
        "  5. You press Start. CS2 opens, records by itself and closes. Do not touch the PC while it records.") | Out-Null
    Add-Box ("Time: the first time about 20-30 minutes (installing helpers). Next times about 5 minutes + recording.`r`n" +
        "Each clip takes roughly 1-2 minutes to record per pass.`r`n`r`n" +
        "Every step explains itself. If something goes wrong, the tool tells you what to do. " +
        "A log is saved in the 'data' folder (wizard.log) if you ever need to show someone what happened.") $C_DIM | Out-Null
    Set-CanNext $true
} }

# ---------- 1 software check
$script:Pages += @{ Title = 'Check software'; Build = {
    Add-Title 'Check the needed software' | Out-Null
    Add-Text 'Green = OK. If something is red, press the button next to it and follow the instructions, then press "Check again".' $C_DIM | Out-Null
    $rows = @()
    $mk = {
        param($name)
        $n = New-Object Windows.Forms.Label; $n.Text = $name; $n.Font = $F_BOLD
        [void](Add-Ctl $n 24 0 230 -Same)
        $st = New-Object Windows.Forms.Label; [void](Add-Ctl $st 44 235 330 -Same)
        $b = New-Object Windows.Forms.Button; $b.FlatStyle = 'Flat'; $b.BackColor = $C_PANEL; $b.ForeColor = $C_TEXT
        $b.FlatAppearance.BorderColor = $C_ACC; $b.Visible = $false
        [void](Add-Ctl $b 32 575 185)
        $script:Y += 10
        return @{ St = $st; B = $b }
    }
    $script:Rw = @{
        Csdm = (& $mk 'CS Demo Manager'); Pg = (& $mk 'PostgreSQL (CSDM database)'); Steam = (& $mk 'Steam')
        Cs2 = (& $mk 'Counter-Strike 2'); Python = (& $mk 'Python'); Py = (& $mk 'Demo reader'); Rec = (& $mk 'HLAE + FFmpeg (recording)')
    }
    $script:DlLbl = Add-Text ' ' $C_ACC; $script:DlLbl.Visible = $false
    $script:DlBar = New-Object Windows.Forms.ProgressBar; $script:DlBar.Minimum = 0; $script:DlBar.Maximum = 1000
    [void](Add-Ctl $script:DlBar 20); $script:DlBar.Visible = $false
    $script:CheckLog = Add-Log 120
    $script:CheckLog.Visible = $false
    Add-Button 'Check again' { Invoke-Checks } | Out-Null

    $script:Rw.Csdm.B.Add_Click({
        if (-not (Get-CsdmDir) -and (Ask-YesNo "Is CS Demo Manager already installed in a custom folder?`r`n`r`nYes = let me pick that folder`r`nNo = open the download page")) {
            $d = New-Object Windows.Forms.FolderBrowserDialog; $d.Description = 'Select the CS Demo Manager install folder (the one with csdm.cmd)'
            if ($d.ShowDialog() -eq 'OK') { $script:S.CsdmDir = $d.SelectedPath; Save-State; Invoke-Checks }
        } else { Start-Process 'https://cs-demo-manager.com' }
    })
    $script:Rw.Pg.B.Add_Click({
        if ($this.Text -eq 'Open Services') { Start-Process services.msc; return }
        $bin = Get-ChildItem "$env:ProgramFiles\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($this.Text -ne 'Fix PATH' -or -not $bin) { Start-Process 'https://cs-demo-manager.com/docs/installation'; return }
        $dir = $bin.DirectoryName
        if (Ask-YesNo "Add this folder to your PATH (only for your Windows user)?`r`n`r`n$dir`r`n`r`nAfter this, restart CS Demo Manager if it is open.") {
            $u = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $u) { $u = '' }
            if ($u -notlike "*$dir*") { [Environment]::SetEnvironmentVariable('Path', ($u.TrimEnd(';') + ';' + $dir).TrimStart(';'), 'User') }
            $env:Path += ";$dir"; Invoke-Checks
        }
    })
    $script:Rw.Steam.B.Add_Click({ Start-Process 'https://store.steampowered.com/about/' })
    $script:Rw.Cs2.B.Add_Click({ Start-Process 'steam://install/730' })
    $script:Rw.Py.B.Add_Click({ Install-Helper })
    $script:Rw.Python.B.Add_Click({ Install-Python })
    $script:Rw.Rec.B.Add_Click({ Install-RecTools })
    Invoke-Checks
} }

function Set-Row($row, [bool]$ok, [string]$text, [string]$btn = '') {
    $row.St.Text = $text
    if ($ok) { $row.St.ForeColor = $C_ACC } else { $row.St.ForeColor = $C_BAD }
    $row.B.Visible = [bool]$btn; $row.B.Text = $btn
}
function Invoke-Checks {
    $all = $true
    $d = Get-CsdmDir
    if (-not $d) { Set-Row $script:Rw.Csdm $false 'Not found. Install it from cs-demo-manager.com (free), then press "Check again".' 'Get it...'; $all = $false }
    else {
        $v = Get-CsdmVersion $d
        if ($v -and $v -lt $MIN_CSDM) { Set-Row $script:Rw.Csdm $false "Version $v is too old. Update to $MIN_CSDM or newer (CSDM offers updates when opened, or download it again)." 'Get it...'; $all = $false }
        else { Set-Row $script:Rw.Csdm $true ("OK  version {0}" -f $(if ($v) { $v } else { '?' })); $script:R.Csdm = $d }
    }

    $svc = @(Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue)
    $psql = (Get-Command psql.exe -ErrorAction SilentlyContinue)
    if ($svc.Count -eq 0) { Set-Row $script:Rw.Pg $false 'PostgreSQL is not installed. CS Demo Manager needs it - see its installation guide.' 'Install guide'; $all = $false }
    elseif (-not ($svc | Where-Object Status -eq 'Running')) { Set-Row $script:Rw.Pg $false 'Installed but not running. Restart the PC, or in Services start the "postgresql" service.' 'Open Services'; $all = $false }
    elseif (-not $psql) { Set-Row $script:Rw.Pg $false 'Running, but psql is not on PATH (CSDM then says "PSQL binary not found").' 'Fix PATH'; $all = $false }
    else { Set-Row $script:Rw.Pg $true 'OK  running' }

    $steam = Get-SteamPath; $script:R.Steam = $steam
    if ($steam) { Set-Row $script:Rw.Steam $true "OK  $steam" } else { Set-Row $script:Rw.Steam $false 'Steam not found.' 'Get Steam'; $all = $false }
    $cs2 = Get-Cs2Path $steam
    if ($cs2) { Set-Row $script:Rw.Cs2 $true 'OK  installed' } else { Set-Row $script:Rw.Cs2 $false 'Counter-Strike 2 not found in your Steam libraries.' 'Install CS2'; $all = $false }

    $py = Find-Python; $script:R.BasePy = $py
    if ($py) { Set-Row $script:Rw.Python $true ("OK  Python {0}`r`n{1}" -f (Get-PyVersion $py), $py) }
    else { Set-Row $script:Rw.Python $false 'No suitable Python (3.11-3.14) found. Needed once to read demos.' 'Install Python 3.12'; $all = $false }
    if (Test-HelperReady) { $script:R.Py = $script:VenvPy; Set-Row $script:Rw.Py $true 'OK  ready' }
    elseif (-not $py) { Set-Row $script:Rw.Py $false 'Install Python first (row above).'; $all = $false }
    else { Set-Row $script:Rw.Py $false 'Needed to read kills from demos. One-time install (about 2-5 minutes, needs internet).' 'Install'; $all = $false }

    $tp = Get-RecToolPaths
    $miss = @(); $custom = @()
    if (-not (Test-Path $tp.Hlae)) { $miss += 'HLAE'; if ($tp.HlaeCustom) { $custom += "HLAE ($($tp.Hlae))" } }
    if (-not (Test-Path $tp.Ffmpeg)) { $miss += 'FFmpeg'; if ($tp.FfmpegCustom) { $custom += "FFmpeg ($($tp.Ffmpeg))" } }
    if ($miss.Count -eq 0) { Set-Row $script:Rw.Rec $true 'OK  both installed' }
    elseif ($custom.Count -gt 0) { Set-Row $script:Rw.Rec $false ("CS Demo Manager is set to use your own copy, but it is missing: " + ($custom -join ', ') + ". Fix the path in CSDM > Settings > Video."); $all = $false }
    else { Set-Row $script:Rw.Rec $false ('Missing: ' + ($miss -join ' and ') + '. One-time download (FFmpeg is about 185 MB).') 'Install'; $all = $false }
    Set-CanNext $all
}
# ---------- HLAE + FFmpeg: installed by this tool into the exact folders CS Demo Manager uses
# (CSDM's own installer follows only one web redirect and can save a web page as the zip -> "Archive read error")
$script:CsdmApp = Join-Path $env:USERPROFILE '.csdm'
function Get-CsdmSettings {
    $f = Join-Path $script:CsdmApp 'settings.json'
    if (Test-Path $f) { try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { Log "csdm settings unreadable: $_" } }
    return $null
}
function Get-RecToolPaths {
    $s = Get-CsdmSettings
    $r = @{ Hlae = (Join-Path $script:CsdmApp 'hlae\hlae.exe'); Ffmpeg = (Join-Path $script:CsdmApp 'ffmpeg\bin\ffmpeg.exe'); HlaeCustom = $false; FfmpegCustom = $false }
    if ($s -and $s.video) {
        $h = $s.video.hlae
        if ($h -and $h.customLocationEnabled -and $h.customExecutableLocation) { $r.Hlae = Join-Path (Split-Path ([string]$h.customExecutableLocation)) 'hlae.exe'; $r.HlaeCustom = $true }
        $f = $s.video.ffmpegSettings
        if ($f -and $f.customLocationEnabled -and $f.customExecutableLocation) { $r.Ffmpeg = [string]$f.customExecutableLocation; $r.FfmpegCustom = $true }
    }
    return $r
}
function Get-GhJson([string]$url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return (Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'cs2-recorder' } -TimeoutSec 30)
}
function Start-PsBg([string]$code, [scriptblock]$onDone, $ctx = $null) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    return (Start-Bg ('powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $enc) $onDone $ctx)
}
function Lit([string]$s) { return "'" + $s.Replace("'", "''") + "'" }   # PowerShell single-quoted literal
function Install-RecTools {
    $tp = Get-RecToolPaths
    $jobs = New-Object Collections.ArrayList
    try {
        if (-not (Test-Path $tp.Hlae)) {
            $rel = @(Get-GhJson 'https://api.github.com/repos/advancedfx/advancedfx/releases') | Where-Object { -not $_.prerelease } | Select-Object -First 1
            $a = @($rel.assets | Where-Object { $_.name -match '^hlae_[\d_]+\.zip$' }) + @($rel.assets | Where-Object { $_.name -match '\.zip$' })
            if (-not $a) { throw 'No HLAE download found on GitHub.' }
            [void]$jobs.Add(@{ Name = "HLAE $($rel.tag_name)"; Kind = 'hlae'; Url = $a[0].browser_download_url; Size = [int64]$a[0].size; Dest = (Join-Path $script:CsdmApp 'hlae') })
        }
        if (-not (Test-Path $tp.Ffmpeg)) {
            $rel = Get-GhJson 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest'
            $best = $null; $bestV = [version]'0.0'
            foreach ($x in $rel.assets) {
                $m = [regex]::Match($x.name, '^ffmpeg-n(\d+\.\d+(?:\.\d+)?)-latest-win64-gpl-[\d.]+\.zip$')
                if ($m.Success -and [version]$m.Groups[1].Value -gt $bestV) { $best = $x; $bestV = [version]$m.Groups[1].Value }
            }
            if (-not $best) { $best = $rel.assets | Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-gpl.zip' } | Select-Object -First 1 }
            if (-not $best) { throw 'No FFmpeg download found on GitHub.' }
            [void]$jobs.Add(@{ Name = "FFmpeg $bestV"; Kind = 'ffmpeg'; Url = $best.browser_download_url; Size = [int64]$best.size; Dest = (Join-Path $script:CsdmApp 'ffmpeg') })
        }
    } catch { Show-Error ("Could not reach GitHub to find the downloads:`r`n" + $_.Exception.Message + "`r`n`r`nCheck the internet connection and press Install again."); return }
    $script:R.ToolJobs = $jobs
    $script:Rw.Rec.B.Enabled = $false
    Next-ToolInstall
}
function Next-ToolInstall {
    if ($script:R.ToolJobs.Count -eq 0) {
        $script:DlBar.Visible = $false; $script:DlLbl.Visible = $false; $script:OnTick = $null
        $script:Rw.Rec.B.Enabled = $true; Invoke-Checks; return
    }
    $j = $script:R.ToolJobs[0]; $script:R.ToolJobs.RemoveAt(0)
    New-Item -ItemType Directory -Force -Path $script:CsdmApp | Out-Null
    $j.Zip = Join-Path $script:Data ("dl_" + $j.Kind + ".zip")
    $script:R.Dl = $j
    $script:DlBar.Style = 'Continuous'; $script:DlBar.Value = 0; $script:DlBar.Visible = $true
    $script:DlLbl.Text = "Downloading $($j.Name)..."; $script:DlLbl.Visible = $true
    $script:OnTick = {
        $d = $script:R.Dl; if (-not $d) { return }
        $len = 0; try { $len = (Get-Item -LiteralPath $d.Zip -ErrorAction Stop).Length } catch {}
        if ($d.Size -gt 0 -and $len -lt $d.Size) {
            $script:DlBar.Style = 'Continuous'; $script:DlBar.Value = [int][Math]::Min(1000, 1000 * $len / $d.Size)
            $script:DlLbl.Text = ('Downloading {0}:  {1:N0} / {2:N0} MB' -f $d.Name, ($len / 1MB), ($d.Size / 1MB))
        } elseif ($len -gt 0) { $script:DlBar.Style = 'Marquee'; $script:DlLbl.Text = "Unpacking $($d.Name)..." }
    }
    $code = @'
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'cs2-recorder')
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    $wc.DownloadFile($url, $zip)
    $fs = [IO.File]::OpenRead($zip); $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte(); $fs.Close()
    if ($b1 -ne 0x50 -or $b2 -ne 0x4B) { throw 'The download is not a zip file (a web page came back instead). Try again in a moment.' }
    $tmp = Join-Path $app ('_extract_' + $kind)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $tar = $null; if ($env:SystemRoot) { $tar = Join-Path $env:SystemRoot 'System32\tar.exe' }
    if ($tar -and (Test-Path $tar)) { & $tar -xf $zip -C $tmp; if ($LASTEXITCODE -ne 0) { throw "Unpacking failed (tar exit $LASTEXITCODE)." } }
    else { Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force }
    if ($kind -eq 'hlae') {
        $exe = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'hlae.exe' | Select-Object -First 1
        if (-not $exe) { throw 'hlae.exe was not found in the download.' }
        $src = $exe.DirectoryName
    } else {
        $exe = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'ffmpeg.exe' | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
        if (-not $exe) { throw 'bin\ffmpeg.exe was not found in the download.' }
        $src = $exe.Directory.Parent.FullName
    }
    if (Test-Path -LiteralPath $dest) { Rename-Item -LiteralPath $dest -NewName ((Split-Path -Leaf $dest) + '_old_' + (Get-Date -Format 'yyyyMMddHHmmss')) }
    Move-Item -LiteralPath $src -Destination $dest
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    'OK'
} catch { 'ERROR: ' + $_.Exception.Message; exit 1 }
'@
    $code = ('$url = {0}; $zip = {1}; $dest = {2}; $app = {3}; $kind = {4}' -f (Lit $j.Url), (Lit $j.Zip), (Lit $j.Dest), (Lit $script:CsdmApp), (Lit $j.Kind)) + "`r`n" + $code
    [void](Start-PsBg $code {
        param($o, $e, $code, $ctx)
        $script:R.Dl = $null
        if ($code -ne 0 -or $o -notmatch 'OK') {
            $msg = ($o + "`n" + $e).Trim()
            $script:R.ToolJobs.Clear(); $script:DlBar.Visible = $false; $script:DlLbl.Visible = $false; $script:OnTick = $null
            $script:Rw.Rec.B.Enabled = $true
            Show-Error ("Installing $($ctx.Name) failed:`r`n$msg`r`n`r`nPress Install to try again.")
            Invoke-Checks; return
        }
        Log "$($ctx.Name) installed to $($ctx.Dest)"
        Next-ToolInstall
    } $j)
}

# ---------- Python 3.12: winget first; fallback = official python.org installer, signature-checked, silent per-user install
$PY_URL = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'   # 3.12.10 = last 3.12 with a Windows installer
$PY_SIZE = 26964224
function Install-Python {
    if (Find-Python) { Invoke-Checks; return }
    if (-not (Ask-YesNo "Install Python 3.12 now?`r`n`r`nIt is free, installs only for your Windows user (no admin needed) and takes 1-3 minutes.")) { return }
    $script:CheckLog.Visible = $true; $script:CheckLog.Text = ''
    $script:Rw.Python.B.Enabled = $false; $script:Rw.Py.B.Enabled = $false
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $script:CheckLog.AppendText("Installing Python 3.12 with winget...`r`n")
        $script:DlLbl.Text = 'Installing Python 3.12 with winget...'; $script:DlLbl.Visible = $true
        $script:DlBar.Style = 'Marquee'; $script:DlBar.Visible = $true
        [void](Start-Bg 'winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements --silent' {
            param($o, $e, $code)
            $script:CheckLog.AppendText(((($o + "`n" + $e) -replace '[^\x20-\x7E\r\n]', '') -replace "`r?`n", "`r`n"))
            if (Find-Python) { Finish-PythonInstall $true; return }
            $script:CheckLog.AppendText("`r`nwinget did not finish (code $code). Trying the official installer from python.org instead...`r`n")
            Install-PythonFromOrg
        })
    } else {
        $script:CheckLog.AppendText("winget is not available on this PC. Using the official installer from python.org.`r`n")
        Install-PythonFromOrg
    }
}
function Install-PythonFromOrg {
    $exe = Join-Path $script:Data 'python-3.12.10-amd64.exe'
    $script:R.Dl = @{ Name = 'Python 3.12.10'; Zip = $exe; Size = $PY_SIZE }
    $script:DlBar.Style = 'Continuous'; $script:DlBar.Value = 0; $script:DlBar.Visible = $true
    $script:DlLbl.Text = 'Downloading Python 3.12.10...'; $script:DlLbl.Visible = $true
    $script:OnTick = {
        $d = $script:R.Dl; if (-not $d) { return }
        $len = 0; try { $len = (Get-Item -LiteralPath $d.Zip -ErrorAction Stop).Length } catch {}
        if ($len -lt $d.Size) {
            $script:DlBar.Style = 'Continuous'; $script:DlBar.Value = [int][Math]::Min(1000, 1000 * $len / $d.Size)
            $script:DlLbl.Text = ('Downloading {0}:  {1:N1} / {2:N1} MB' -f $d.Name, ($len / 1MB), ($d.Size / 1MB))
        } else { $script:DlBar.Style = 'Marquee'; $script:DlLbl.Text = 'Installing Python 3.12.10 (about 1-2 minutes)...' }
    }
    $code = @'
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
    $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'cs2-recorder'); $wc.DownloadFile($url, $exe)
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
        Remove-Item -LiteralPath $exe -Force
        throw ("The downloaded installer is not validly signed by the Python Software Foundation (status: " + $sig.Status + "). It was deleted for safety.")
    }
    $p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList '/quiet', 'InstallAllUsers=0', 'InstallLauncherAllUsers=0', 'Include_launcher=1', 'PrependPath=1', 'Include_test=0', 'Include_doc=0', 'Shortcuts=0'
    if ($p.ExitCode -ne 0) { throw ("The Python installer ended with code " + $p.ExitCode + ".") }
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    'OK'
} catch { 'ERROR: ' + $_.Exception.Message; exit 1 }
'@
    $code = ('$url = {0}; $exe = {1}' -f (Lit $PY_URL), (Lit $exe)) + "`r`n" + $code
    [void](Start-PsBg $code {
        param($o, $e, $code)
        $script:R.Dl = $null; $script:OnTick = $null
        $script:CheckLog.AppendText((($o + "`n" + $e).Trim() -replace "`r?`n", "`r`n") + "`r`n")
        Finish-PythonInstall ([bool](Find-Python))
    })
}
function Finish-PythonInstall([bool]$ok) {
    $script:DlBar.Visible = $false; $script:DlLbl.Visible = $false; $script:OnTick = $null
    $script:Rw.Python.B.Enabled = $true; $script:Rw.Py.B.Enabled = $true
    if ($ok) { $script:CheckLog.AppendText("Python 3.12 is installed.`r`n") }
    else {
        Show-Error ("Python could not be installed automatically. Details are in the box.`r`n`r`n" +
            "Manual way: python.org opens now. Download 'Windows installer (64-bit)' for Python 3.12.10, run it, tick 'Add python.exe to PATH', press 'Install Now', then press 'Check again' here.")
        Start-Process 'https://www.python.org/downloads/release/python-31210/'
    }
    Invoke-Checks
}

function Install-Helper {
    $script:CheckLog.Visible = $true
    $script:CheckLog.Text = "Looking for Python...`r`n"
    $py = Find-Python
    if (-not $py) { Show-Error 'Install Python first with the "Install Python 3.12" button.'; Invoke-Checks; return }
    $venv = Join-Path $script:Data 'pyenv'
    $script:CheckLog.AppendText("Using $py`r`nCreating a private Python environment and installing demoparser2 (may take a few minutes)...`r`n")
    $script:Rw.Py.B.Enabled = $false
    $cmd = (Q $py) + ' -m venv ' + (Q $venv) + ' && ' + (Q $script:VenvPy) + ' -m pip install --disable-pip-version-check demoparser2 zstandard numpy pandas'
    [void](Start-Bg $cmd {
        param($o, $e, $code)
        $script:Rw.Py.B.Enabled = $true
        $script:CheckLog.AppendText((($o + "`n" + $e) -replace "`r?`n", "`r`n"))
        if (Test-HelperReady) { $script:CheckLog.AppendText("`r`nDone.`r`n") } else { Show-Error "Installing the demo reader failed (code $code). Check your internet connection and press Install again. Details are in the box." }
        Invoke-Checks
    })
}

# ---------- 2 steam account
$script:Pages += @{ Title = 'Steam account'; Build = {
    Add-Title 'Which Steam account will record?' | Out-Null
    Add-Box ("STRONGLY RECOMMENDED: record on a separate Steam account, not the one you play competitive on.`r`n`r`n" +
        "Why: recording starts CS2 with HLAE (a tool that hooks into the game) and changes game settings such as graphics. " +
        "Keeping it on a second account keeps your main account and your own settings completely untouched. " +
        "CS2 is free to play, so a free second Steam account is enough.`r`n`r`n" +
        "To switch: Steam menu > Change account... (sign in to the second account), then come back here.") $C_WARN | Out-Null
    Add-Text ("VAC safety: recording only ever starts CS2 with the -insecure option (no VAC, no official servers), which CS Demo Manager adds by itself. " +
        "This tool also double-checks it while recording and closes CS2 at once if it is missing. Never start HLAE yourself without -insecure.") $C_DIM | Out-Null
    $acc = @(Get-SteamAccounts $script:R.Steam)
    if ($acc.Count -eq 0) { Add-Text 'Could not read the Steam account list. That is OK - just check the Steam window yourself.' $C_DIM | Out-Null }
    Add-Text 'Account that is signed in to Steam right now (Steam remembers the last one):' -Bold | Out-Null
    $cb = New-Object Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'
    foreach ($a in $acc) {
        $t = '{0}   (login: {1})' -f $a.Persona, $a.Account; if ($a.Recent) { $t += '   <- last signed in' }
        [void]$cb.Items.Add($t)
    }
    [void](Add-Ctl $cb 28 0 500)
    $script:AccCombo = $cb; $script:AccList = $acc
    $idx = -1
    for ($k = 0; $k -lt $acc.Count; $k++) { if ($acc[$k].Id -eq $script:S.AccountId) { $idx = $k } }
    if ($idx -lt 0) { for ($k = 0; $k -lt $acc.Count; $k++) { if ($acc[$k].Recent) { $idx = $k } } }
    if ($idx -ge 0) { $cb.SelectedIndex = $idx }
    Add-Text 'Now look at the top-right corner of the Steam window and check the name there matches.' $C_DIM | Out-Null
    $script:RbSep = New-Object Windows.Forms.RadioButton; $script:RbSep.Text = 'Yes - this is my separate recording account'
    [void](Add-Ctl $script:RbSep 26)
    $script:RbMain = New-Object Windows.Forms.RadioButton; $script:RbMain.Text = 'This is my main account - I understand the risk and want to continue'
    [void](Add-Ctl $script:RbMain 26)
    if ($script:S.AccountKind -eq 'separate') { $script:RbSep.Checked = $true }
    $upd = {
        $ok = ($script:RbSep.Checked -or $script:RbMain.Checked)
        if ($script:AccList.Count -gt 0 -and $script:AccCombo.SelectedIndex -lt 0) { $ok = $false }
        Set-CanNext $ok
    }
    $script:RbSep.Add_CheckedChanged($upd); $script:RbMain.Add_CheckedChanged($upd); $cb.Add_SelectedIndexChanged($upd)
    & $upd
} ; Next = {
    if ($script:AccList.Count -gt 0 -and $script:AccCombo.SelectedIndex -ge 0) { $script:S.AccountId = $script:AccList[$script:AccCombo.SelectedIndex].Id }
    if ($script:RbSep.Checked) { $script:S.AccountKind = 'separate' } else { $script:S.AccountKind = 'main' }
    Save-State; return $true
} }

# ---------- 3 graphics
$script:Pages += @{ Title = 'Graphics'; Build = {
    Add-Title 'Set graphics to maximum' | Out-Null
    Add-Text 'The recording uses the graphics settings of the Steam account from the previous step. Do this every time before recording - the settings have been seen to reset by themselves.' $C_DIM | Out-Null
    Add-Text ("1. Start CS2 with the recording account (button below).`r`n" +
        "2. Settings (gear icon) > Game > Enable Developer Console (~): Yes.`r`n" +
        "3. Settings > Video > Advanced Video: set every option to its highest value.`r`n" +
        "     - FidelityFX Super Resolution: Disabled (Highest Quality)`r`n" +
        "     - Wait for Vertical Sync: Disabled`r`n" +
        "     - Everything else (multisampling, shadows, textures, effects, shaders, particles, ambient occlusion, HDR...): the highest option`r`n" +
        "   Press Apply.`r`n" +
        "4. Open the console with the ~ key (the key under Esc), paste the command below, press Enter. This saves the settings for good.`r`n" +
        "5. Quit CS2. The tool starts CS2 by itself when recording.") | Out-Null
    $y0 = $script:Y
    Add-Button 'Start CS2' { Start-Process 'steam://rungameid/730' } 0 200 -Same | Out-Null
    Add-Button 'Copy:  host_writeconfig' { Copy-Text 'host_writeconfig' } 220 240 | Out-Null
    $f = Get-VideoCfgPath $script:R.Steam $script:S.AccountId
    if ($f -and (Test-Path $f)) {
        $ti = (Get-Item $f).LastWriteTime
        Add-Text ("Video settings file of this account was last saved: {0:dd.MM.yyyy HH:mm}. After step 4 this time should change to now." -f $ti) $C_DIM | Out-Null
        Add-Button 'Show the settings file' { Start-Process notepad.exe -ArgumentList (Q (Get-VideoCfgPath $script:R.Steam $script:S.AccountId)) } 0 240 | Out-Null
    } elseif ($f) { Add-Text 'No saved video settings found for this account yet - doing steps 1-4 creates them.' $C_DIM | Out-Null }
    if ($script:S.GraphicsAt) { Add-Text ("Last confirmed: " + $script:S.GraphicsAt) $C_DIM | Out-Null }
    $script:GfxChk = Add-Check 'Graphics are at maximum and I ran host_writeconfig. CS2 is closed again.' $false { Set-CanNext $script:GfxChk.Checked }
} ; Next = { $script:S.GraphicsAt = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Save-State; return $true } }

# ---------- 4 demo
$script:Pages += @{ Title = 'Demo'; Build = {
    Add-Title 'Choose the demo' | Out-Null
    Add-Text ("Where to get demos: FACEIT match page > Watch demo / Download. Premier/matchmaking demos: CS2 main menu > Watch > Your matches " +
        "(they expire after a few weeks). Compressed files (.dem.zst, .dem.bz2, .dem.gz) are fine - the tool unpacks them.") $C_DIM | Out-Null
    Add-Box ("Important: a demo recorded on an older CS2 update can crash the game when it loads. If CS2 crashes right before the demo starts playing, " +
        "that demo cannot be recorded with the current game version - try a newer demo.") $C_WARN | Out-Null
    $script:DemoLbl = Add-Text $(if ($script:S.Demo) { "Selected: $($script:S.Demo)" } else { 'No demo selected.' }) -Bold
    Add-Button 'Choose demo file...' { Select-Demo } | Out-Null
    $script:DemoInfo = Add-Log 150
    $script:DemoInfo.Visible = $false
    if ($script:S.Demo -and (Test-Path $script:S.Demo) -and $script:R.Players.Count -gt 0) { Show-DemoInfo $script:R.DemoInfo; Set-CanNext $true }
} }
function Select-Demo {
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = 'CS2 demos (*.dem;*.zst;*.bz2;*.gz)|*.dem;*.zst;*.bz2;*.gz|All files|*.*'
    if ($script:S.Demo) { try { $d.InitialDirectory = Split-Path $script:S.Demo } catch {} }
    if ($d.ShowDialog() -ne 'OK') { return }
    $p = $d.FileName
    $script:R.Players = @(); Set-CanNext $false
    $script:DemoInfo.Visible = $true
    if ($p -match '\.(zst|bz2|gz)$') {
        $dst = $p -replace '\.(zst|bz2|gz)$', ''
        if (-not $dst.ToLower().EndsWith('.dem')) { $dst += '.dem' }
        if (Test-Path $dst) { $script:DemoInfo.Text = "Already unpacked: $dst`r`n"; Read-Demo $dst; return }
        $script:DemoInfo.Text = "Unpacking to $dst ...`r`n"
        [void](Start-Bg (Helper ('decompress ' + (Q $p) + ' ' + (Q $dst))) {
            param($o, $e, $code, $ctx)
            $r = Parse-Json $o $e
            if ($r.ok) { Read-Demo $ctx } else { $script:DemoInfo.AppendText("FAILED: $($r.error)`r`n"); Show-Error "Could not unpack the demo:`r`n$($r.error)" }
        } $dst)
        return
    }
    Read-Demo $p
}
function Read-Demo([string]$p) {
    $script:S.Demo = $p; $script:DemoLbl.Text = "Selected: $p"
    $script:DemoInfo.AppendText("Reading the demo (can take up to a minute)...`r`n")
    [void](Start-Bg (Helper ('info ' + (Q $p))) {
        param($o, $e, $code)
        $r = Parse-Json $o $e
        if (-not $r.ok) { $script:DemoInfo.AppendText("FAILED: $($r.error)`r`n"); Show-Error "This file could not be read as a CS2 demo:`r`n$($r.error)"; return }
        $script:R.DemoInfo = $r; $script:R.Players = @($r.players)
        Show-DemoInfo $r; Save-State
        Set-CanNext ($script:R.Players.Count -gt 0)
    })
}
function Show-DemoInfo($r) {
    $script:DemoInfo.Visible = $true
    $t = "Map: $($r.map)`r`nPlayers with kills: $(@($r.players | Where-Object { $_.kills -gt 0 }).Count)`r`n"
    foreach ($p in $r.header.PSObject.Properties) { if ($p.Name -match 'version|build|patch|server|network') { $t += "$($p.Name): $($p.Value)`r`n" } }
    $script:DemoInfo.Text = $t
}

# ---------- 5 frags
$script:Pages += @{ Title = 'Frags'; Build = {
    Add-Title 'Choose the player and the kills' | Out-Null
    Add-Text 'Player:' -Bold | Out-Null
    $cb = New-Object Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'
    $sel = -1; $k = 0
    foreach ($p in $script:R.Players) {
        [void]$cb.Items.Add(('{0}   ({1} kills)' -f $p.name, $p.kills))
        if ($p.steamid -eq $script:S.LastPlayer) { $sel = $k }; $k++
    }
    [void](Add-Ctl $cb 28 0 420)
    $script:PlCombo = $cb
    $script:KillList = New-Object Windows.Forms.CheckedListBox
    $script:KillList.CheckOnClick = $true; $script:KillList.Font = $F_MONO
    $script:KillList.BackColor = [Drawing.Color]::Black; $script:KillList.ForeColor = $C_TEXT
    [void](Add-Ctl $script:KillList 230)
    Add-Button 'Select all' { for ($i = 0; $i -lt $script:KillList.Items.Count; $i++) { $script:KillList.SetItemChecked($i, $true) }; Update-ClipPreview } 0 150 -Same | Out-Null
    Add-Button 'Select none' { for ($i = 0; $i -lt $script:KillList.Items.Count; $i++) { $script:KillList.SetItemChecked($i, $false) }; Update-ClipPreview } 160 150 -Same | Out-Null
    Add-Button 'Select rounds with 3+ kills' { Select-MultiKills } 320 250 | Out-Null

    $mkNum = {
        param($label, $val, $x, $min, $max, $dec)
        $l = New-Object Windows.Forms.Label; $l.Text = $label; [void](Add-Ctl $l 22 $x 190 -Same)
        $n = New-Object Windows.Forms.NumericUpDown; $n.Minimum = $min; $n.Maximum = $max; $n.DecimalPlaces = $dec; $n.Increment = 0.5
        $n.Value = [decimal]$val; $n.Add_ValueChanged({ Update-ClipPreview })
        $script:Y += 22; [void](Add-Ctl $n 26 $x 90 -Same); $script:Y -= 22
        return $n
    }
    $script:NumBefore = & $mkNum 'Seconds before first kill' $script:S.Before 0 1 15 1
    $script:NumAfter = & $mkNum 'Seconds after last kill' $script:S.After 250 0 10 1
    $script:NumJoin = & $mkNum 'Join kills closer than (s)' $script:S.Join 500 1 30 1
    $script:Y += 58
    $script:ClipLbl = Add-Text ' ' $C_ACC
    $script:ClipLbl.Height = 90
    $script:KillList.Add_ItemCheck({ $form.BeginInvoke([Action] { Update-ClipPreview }) | Out-Null })
    $cb.Add_SelectedIndexChanged({ Load-Kills })
    if ($sel -ge 0) { $cb.SelectedIndex = $sel } elseif ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
} ; Next = {
    $script:S.Before = [double]$script:NumBefore.Value; $script:S.After = [double]$script:NumAfter.Value; $script:S.Join = [double]$script:NumJoin.Value
    $script:R.Clips = Build-Clips (Get-CheckedKills)
    Save-State; return ($script:R.Clips.Count -gt 0)
} }
function Get-Player { if ($script:PlCombo.SelectedIndex -lt 0) { return $null }; return $script:R.Players[$script:PlCombo.SelectedIndex] }
function Load-Kills {
    $p = Get-Player; if (-not $p) { return }
    $script:S.LastPlayer = $p.steamid; $script:R.Player = $p
    $script:KillList.Items.Clear(); [void]$script:KillList.Items.Add('Loading kills...')
    [void](Start-Bg (Helper ('kills ' + (Q $script:S.Demo) + ' ' + $p.steamid)) {
        param($o, $e)
        $r = Parse-Json $o $e
        $script:KillList.Items.Clear()
        if (-not $r.ok) { Show-Error "Could not read the kills:`r`n$($r.error)"; return }
        $script:R.Kills = @($r.kills); $script:R.Deaths = @($r.deaths)
        $per = @{}; foreach ($k in $script:R.Kills) { $per[[string]$k.round] = 1 + [int]$per[[string]$k.round] }
        foreach ($k in $script:R.Kills) {
            $tags = @(); if ($k.headshot) { $tags += 'HS' }; if ($k.smoke) { $tags += 'smoke' }; if ($k.noscope) { $tags += 'noscope' }
            if ($k.wallbang) { $tags += 'wallbang' }; if ($k.blind) { $tags += 'blind' }
            $n = $per[[string]$k.round]; $rk = '   '; if ($n -ge 2) { $rk = "$($n)K " }
            [void]$script:KillList.Items.Add(('R{0,-3} {1}  tick {2,-7} {3,-14} -> {4,-18} {5}' -f $k.round, $rk, $k.tick, $k.weapon, $k.victim, ($tags -join ' ')))
        }
        if ($script:R.Kills.Count -eq 0) { [void]$script:KillList.Items.Add('This player has no kills in this demo.') }
        Update-ClipPreview
    })
}
function Get-CheckedKills {
    $out = @()
    foreach ($i in $script:KillList.CheckedIndices) { if ($i -lt $script:R.Kills.Count) { $out += $script:R.Kills[$i] } }
    return , $out
}
function Select-MultiKills {
    $per = @{}; foreach ($k in $script:R.Kills) { $per[[string]$k.round] = 1 + [int]$per[[string]$k.round] }
    for ($i = 0; $i -lt $script:R.Kills.Count; $i++) { $script:KillList.SetItemChecked($i, ($per[[string]$script:R.Kills[$i].round] -ge 3)) }
    Update-ClipPreview
}
function Update-ClipPreview {
    if (-not $script:ClipLbl) { return }
    $script:S.Before = [double]$script:NumBefore.Value; $script:S.After = [double]$script:NumAfter.Value; $script:S.Join = [double]$script:NumJoin.Value
    $clips = Build-Clips (Get-CheckedKills)
    if ($clips.Count -eq 0) { $script:ClipLbl.Text = 'Tick the kills you want to record.'; Set-CanNext $false; return }
    $t = "$($clips.Count) clip(s) will be recorded:`r`n"
    foreach ($c in $clips) { $t += ('  {0}: round {1}, {2} kill(s), {3:N1} s' -f $c.Name, $c.Round, $c.Kills.Count, (($c.End - $c.Start) / $TICK)) + "`r`n" }
    $script:ClipLbl.Text = $t
    $script:ClipLbl.Height = Measure-H $t $F_BODY 760
    Set-CanNext $true
}

# ---------- 6 layers & quality
$script:Pages += @{ Title = 'Layers & quality'; Build = {
    Add-Title 'What to record' | Out-Null
    Add-Text 'Always recorded: the normal first-person video with killfeed and game sound. Tick the extra layers you want:' $C_DIM | Out-Null
    $script:LayerChecks = @{}
    foreach ($l in $LAYERS) {
        $c = Add-Check $l.Name ($script:S.Layers -contains $l.Key) { Update-Estimate } 0 270 -Same
        $script:LayerChecks[$l.Key] = $c
        $d = New-Object Windows.Forms.Label; $d.Text = $l.Desc; $d.ForeColor = $C_DIM
        [void](Add-Ctl $d 38 280 480)
    }
    Add-Button 'Recommended set' { foreach ($k in $script:LayerChecks.Keys) { $script:LayerChecks[$k].Checked = (@('clean', 'hud', 'depth', 'players', 'viewModel', 'particlesBlack') -contains $k) } } 0 180 -Same | Out-Null
    Add-Button 'All' { foreach ($c in $script:LayerChecks.Values) { $c.Checked = $true } } 190 90 -Same | Out-Null
    Add-Button 'None' { foreach ($c in $script:LayerChecks.Values) { $c.Checked = $false } } 290 90 | Out-Null

    $l1 = New-Object Windows.Forms.Label; $l1.Text = 'Resolution'; [void](Add-Ctl $l1 22 0 120 -Same)
    $script:ResCombo = New-Object Windows.Forms.ComboBox; $script:ResCombo.DropDownStyle = 'DropDown'
    foreach ($r in '1920x1080', '2560x1440', '3840x2160') { [void]$script:ResCombo.Items.Add($r) }
    $script:ResCombo.Text = "$($script:S.Width)x$($script:S.Height)"
    [void](Add-Ctl $script:ResCombo 26 125 130 -Same)
    $l2 = New-Object Windows.Forms.Label; $l2.Text = 'Frames per second'; [void](Add-Ctl $l2 22 290 140 -Same)
    $script:FpsCombo = New-Object Windows.Forms.ComboBox; $script:FpsCombo.DropDownStyle = 'DropDown'
    foreach ($f in '60', '120', '240') { [void]$script:FpsCombo.Items.Add($f) }
    $script:FpsCombo.Text = [string]$script:S.Fps
    [void](Add-Ctl $script:FpsCombo 26 435 80)
    Add-Text ('Pick a preset or type your own, for example 1280x600 (width x height, even numbers) and any frame rate from 1 to 10000. ' +
        '60 fps is normal; 120 or 240 gives smooth slow motion (bigger files, slower recording).') $C_DIM | Out-Null
    $script:ResCombo.Add_TextChanged({ Update-Estimate }); $script:FpsCombo.Add_TextChanged({ Update-Estimate })

    $l3 = New-Object Windows.Forms.Label; $l3.Text = 'Save to folder'; [void](Add-Ctl $l3 22 0 120 -Same)
    $script:OutBox = New-Object Windows.Forms.TextBox; $script:OutBox.Text = $script:S.OutDir
    [void](Add-Ctl $script:OutBox 26 125 450 -Same)
    Add-Button 'Browse...' {
        $d = New-Object Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') { $script:OutBox.Text = $d.SelectedPath }
    } 585 110 | Out-Null
    $script:OutBox.Add_TextChanged({ Update-Estimate })
    $script:EstLbl = Add-Text ' '
    $script:EstLbl.Height = 60
    Update-Estimate
} ; Next = {
    $p = $script:OutBox.Text.Trim().TrimEnd('\')
    $bad = Test-SafePath $p
    if ($bad) { Show-Error $bad; return $false }
    try { New-Item -ItemType Directory -Force -Path $p | Out-Null } catch { Show-Error "Cannot create the folder $p"; return $false }
    $script:S.OutDir = $p
    $script:S.Layers = @($LAYERS | Where-Object { $script:LayerChecks[$_.Key].Checked } | ForEach-Object { $_.Key })
    $rc = Check-Res $script:ResCombo.Text; if ($rc.Err) { Show-Error $rc.Err; return $false }
    $fc = Check-Fps $script:FpsCombo.Text; if ($fc.Err) { Show-Error $fc.Err; return $false }
    $script:S.Width = $rc.W; $script:S.Height = $rc.H; $script:S.Fps = $fc.N
    Save-State; return $true
} }
function Parse-Res([string]$t) {
    $m = [regex]::Match([string]$t, '^\s*(\d{1,5})\s*[xX*]\s*(\d{1,5})\s*$')
    if (-not $m.Success) { return $null }
    return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}
function Check-Res([string]$t) {
    $r = Parse-Res $t
    if (-not $r) { return @{ Err = 'Resolution must look like 1920x1080 (width x height).' } }
    $w = $r[0]; $h = $r[1]
    if ($w -lt 320 -or $h -lt 200 -or $w -gt 7680 -or $h -gt 4320) { return @{ Err = 'Resolution must be between 320x200 and 7680x4320.' } }
    if (($w % 2) -ne 0 -or ($h % 2) -ne 0) { return @{ Err = 'Width and height must be even numbers (the video encoder needs that), for example 1280x600.' } }
    $warn = $null
    if ($w -lt 800 -or $h -lt 600) { $warn = 'Below 800x600: CS Demo Manager does not normally allow this size, so it may not work.' }
    return @{ W = $w; H = $h; Warn = $warn }
}
function Check-Fps([string]$t) {
    $n = 0
    if (-not [int]::TryParse(([string]$t).Trim(), [ref]$n)) { return @{ Err = 'Frames per second must be a whole number, for example 60.' } }
    if ($n -lt 1 -or $n -gt 10000) { return @{ Err = 'Frames per second must be between 1 and 10000.' } }
    $warn = $null
    if ($n -gt 480) { $warn = 'Very high frame rate: recording takes much longer and the files get much bigger.' }
    return @{ N = $n; Warn = $warn }
}
function Get-SizeMb([string[]]$keys, [int]$fps, [double]$seconds, [int]$w = 1920, [int]$h = 1080) {
    $scale = ([double]$w * [double]$h * $fps) / (1920.0 * 1080 * 60)
    $mb = 6  # CSDM's own video
    foreach ($k in $keys) { $mb += (Get-Layer $k).Mb }
    return $mb * $scale * $seconds
}
function Update-Estimate {
    if (-not $script:EstLbl) { return }
    $secs = 0; foreach ($c in $script:R.Clips) { $secs += ($c.End - $c.Start) / $TICK }
    $keys = @($LAYERS | Where-Object { $script:LayerChecks[$_.Key].Checked } | ForEach-Object { $_.Key })
    $rc = Check-Res $script:ResCombo.Text; $fc = Check-Fps $script:FpsCombo.Text
    $problems = @(); $warns = @()
    foreach ($c in $rc, $fc) { if ($c.Err) { $problems += $c.Err } elseif ($c.Warn) { $warns += $c.Warn } }
    $mb = 0
    if ($problems.Count -eq 0) { $mb = Get-SizeMb $keys $fc.N $secs $rc.W $rc.H }
    $free = $null
    try { $free = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:OutBox.Text))).AvailableFreeSpace / 1GB } catch {}
    $t = ("First-person pass: {0:N1} s of footage, roughly {1:N1} GB (rough estimate)." -f $secs, ($mb / 1024))
    if ($free -ne $null) { $t += ("  Free space on that drive: {0:N0} GB." -f $free) }
    $bad = Test-SafePath $script:OutBox.Text
    if ($bad) { $problems += $bad }
    foreach ($x in $problems) { $t += "`r`n" + $x }
    foreach ($x in $warns) { $t += "`r`nNote: " + $x }
    if ($problems.Count -gt 0) { $script:EstLbl.ForeColor = $C_BAD } elseif ($warns.Count -gt 0) { $script:EstLbl.ForeColor = $C_WARN } else { $script:EstLbl.ForeColor = $C_DIM }
    $script:EstLbl.Text = $t
    $script:EstLbl.Height = Measure-H $t $F_BODY 760
    Set-CanNext ($problems.Count -eq 0)
}

# ---------- 7 camera
$script:Pages += @{ Title = 'Camera shot'; Build = {
    Add-Title 'Cinematic camera shot (optional)' | Out-Null
    Add-Text ("The tool can also record every clip a second time from a third-person camera that follows the player over the shoulder " +
        "and looks where he aims. The path is computed from the demo - no manual camera flying.") | Out-Null
    Add-Box ("Honest warning: the tool has no 3D map data. It keeps the camera inside places where players walked during the match, " +
        "which avoids most walls, but the camera can still clip through a corner, door or object. Always watch the result. " +
        "The first second of each camera clip is a lead-in while the camera settles; start your edit after it.") $C_WARN | Out-Null
    $script:CamChk = Add-Check 'Record the camera shot too' ([bool]$script:S.CamOn) { $script:CamPanelState.Invoke() }
    $l = New-Object Windows.Forms.Label; $l.Text = 'Zoom (field of view)'; [void](Add-Ctl $l 22 0 170 -Same)
    $script:FovBar = New-Object Windows.Forms.TrackBar; $script:FovBar.Minimum = 30; $script:FovBar.Maximum = 90; $script:FovBar.TickFrequency = 5
    $script:FovBar.Value = [int]$script:S.Fov; [void](Add-Ctl $script:FovBar 40 175 360 -Same)
    $script:FovLbl = New-Object Windows.Forms.Label; [void](Add-Ctl $script:FovLbl 22 545 210)
    $script:Y += 18
    $fovText = { $script:FovLbl.Text = "$($script:FovBar.Value)   (smaller = more zoom)" }
    $script:FovBar.Add_ValueChanged($fovText); & $fovText
    Add-Text '40-55 looks cinematic and zoomed. 60-75 shows more of the area.' $C_DIM | Out-Null
    $l2 = New-Object Windows.Forms.Label; $l2.Text = 'Distance'; [void](Add-Ctl $l2 22 0 170 -Same)
    $script:DistCombo = New-Object Windows.Forms.ComboBox; $script:DistCombo.DropDownStyle = 'DropDownList'
    foreach ($d in 'Close (80)', 'Medium (110)', 'Far (150)') { [void]$script:DistCombo.Items.Add($d) }
    $script:DistCombo.SelectedIndex = $(switch ([int]$script:S.CamDist) { 80 { 0 } 150 { 2 } default { 1 } })
    [void](Add-Ctl $script:DistCombo 26 175 160)
    $l3 = New-Object Windows.Forms.Label; $l3.Text = 'Frames per second'; [void](Add-Ctl $l3 22 0 170 -Same)
    $script:CamFps = New-Object Windows.Forms.ComboBox; $script:CamFps.DropDownStyle = 'DropDown'
    foreach ($f in '60', '120', '240') { [void]$script:CamFps.Items.Add($f) }
    $script:CamFps.Text = [string]$script:S.CamFps
    [void](Add-Ctl $script:CamFps 26 175 80 -Same)
    $script:CamFpsMsg = New-Object Windows.Forms.Label; $script:CamFpsMsg.ForeColor = $C_DIM; $script:CamFpsMsg.Text = 'preset or any number 1-10000'
    [void](Add-Ctl $script:CamFpsMsg 40 265 495)
    $script:CamFps.Add_TextChanged({
        $fc = Check-Fps $script:CamFps.Text
        if ($fc.Err) { $script:CamFpsMsg.Text = $fc.Err; $script:CamFpsMsg.ForeColor = $C_BAD; Set-CanNext $false }
        elseif ($fc.Warn) { $script:CamFpsMsg.Text = $fc.Warn; $script:CamFpsMsg.ForeColor = $C_WARN; Set-CanNext $true }
        else { $script:CamFpsMsg.Text = 'preset or any number 1-10000'; $script:CamFpsMsg.ForeColor = $C_DIM; Set-CanNext $true }
    })
    Add-Text 'Camera layers:' -Bold | Out-Null
    $script:CamChecks = @{}
    $col = 0
    foreach ($ly in ($LAYERS | Where-Object { $_.Cam })) {
        $c = Add-Check $ly.Name ($script:S.CamLayers -contains $ly.Key) $null ($col * 380) 370 -Same:($col -eq 0)
        $script:CamChecks[$ly.Key] = $c; $col = 1 - $col
    }
    if ($col -eq 1) { $script:Y += 34 }
    $script:CamPanelState = [Action] {
        $on = $script:CamChk.Checked
        foreach ($c in $script:CamChecks.Values) { $c.Enabled = $on }
        $script:FovBar.Enabled = $on; $script:DistCombo.Enabled = $on; $script:CamFps.Enabled = $on
    }
    $script:CamPanelState.Invoke()
    Set-CanNext $true
} ; Next = {
    $script:S.CamOn = $script:CamChk.Checked
    $script:S.Fov = $script:FovBar.Value
    $script:S.CamDist = @(80, 110, 150)[$script:DistCombo.SelectedIndex]
    if ($script:CamChk.Checked) { $fc = Check-Fps $script:CamFps.Text; if ($fc.Err) { Show-Error $fc.Err; return $false }; $script:S.CamFps = $fc.N }
    $script:S.CamLayers = @($script:CamChecks.Keys | Where-Object { $script:CamChecks[$_].Checked })
    Save-State; return $true
} }

# ---------- 8 record
$script:Pages += @{ Title = 'Record'; Build = {
    Add-Title 'Ready to record' | Out-Null
    $p = $script:R.Player
    $t = "Demo: $(Split-Path -Leaf $script:S.Demo)   Map: $($script:R.DemoInfo.map)`r`nPlayer: $($p.name)`r`n"
    $t += "First-person: $($script:S.Width)x$($script:S.Height) at $($script:S.Fps) fps, layers: " + $(if ($script:S.Layers.Count) { ($script:S.Layers -join ', ') } else { 'none (only the normal video)' }) + "`r`n"
    if ($script:S.CamOn) { $t += "Camera shot: FOV $($script:S.Fov), $($script:S.CamFps) fps, layers: " + $(if ($script:S.CamLayers.Count) { ($script:S.CamLayers -join ', ') } else { 'none (only the normal video)' }) + "`r`n" }
    else { $t += "Camera shot: off`r`n" }
    $t += "Clips: " + (($script:R.Clips | ForEach-Object { $_.Name }) -join ', ')
    Add-Text $t | Out-Null
    Add-Text 'Before you press Start:' -Bold | Out-Null
    $script:Pre = @(
        (Add-Check 'Steam is open and signed in to the account from step 2' $false { Update-RecReady }),
        (Add-Check 'CS2 is closed (the tool starts it), and the CS Demo Manager window is closed' $false { Update-RecReady }),
        (Add-Check 'I will not use the mouse/keyboard while it records, and the PC will not go to sleep' $false { Update-RecReady })
    )
    $script:TestRun = Add-Check 'Test run: record only the first clip (good idea the very first time)' $false $null
    $y0 = $script:Y
    $script:BtnStart = Add-Button 'START RECORDING' { Start-Recording } 0 220 -Same
    $script:BtnStart.Font = $F_BOLD; $script:BtnStart.Enabled = $false
    $script:BtnCancel = Add-Button 'Stop' { Stop-Recording } 230 100 -Same
    $script:BtnCancel.Enabled = $false
    Add-Button 'Manual instructions (if automatic fails)' { Open-Manual } 340 300 | Out-Null
    $script:RecLbl = Add-Text ' ' $C_ACC -Bold
    $script:RecLog = Add-Log 200
} }
function Update-RecReady {
    $ok = $true; foreach ($c in $script:Pre) { if (-not $c.Checked) { $ok = $false } }
    $script:BtnStart.Enabled = $ok -and -not $script:R.Recording
}

# ---------- 9 done
$script:Pages += @{ Title = 'Done'; Build = {
    Add-Title 'Results' | Out-Null
    Add-Text $script:R.ResultText | Out-Null
    Add-Button 'Open the output folder' { Start-Process explorer.exe -ArgumentList (Q $script:R.RunDir) } | Out-Null
    Add-Button 'Open RESULT.txt (kill times for editing)' { Start-Process notepad.exe -ArgumentList (Q (Join-Path $script:R.RunDir 'RESULT.txt')) } 0 320 | Out-Null
    Add-Button 'Record more (back to choosing kills)' { $script:R.Recording = $false; Show-Page 5 } 0 320 | Out-Null
    Set-CanNext $true
} }

# ------------------------------------------------------------------ recording
function New-RunFiles {
    $demoBase = [IO.Path]::GetFileNameWithoutExtension($script:S.Demo)
    if ($demoBase.Length -gt 40) { $demoBase = $demoBase.Substring(0, 40) }
    $demoBase = $demoBase -replace '[^A-Za-z0-9_.-]', '_'
    $run = Join-Path $script:S.OutDir ('{0}_{1:yyyyMMdd-HHmm}' -f $demoBase, (Get-Date))
    New-Item -ItemType Directory -Force -Path $run | Out-Null
    $script:R.RunDir = $run
    $clips = $script:R.Clips
    if ($script:TestRun.Checked) { $clips = @($clips[0]) }
    $script:R.RunClips = $clips
    $p = $script:R.Player
    $povSeq = @(); $camSeq = @(); $manual = New-Object Text.StringBuilder
    [void]$manual.AppendLine('MANUAL MODE - only if the automatic recording fails')
    [void]$manual.AppendLine('====================================================')
    [void]$manual.AppendLine('1. Open CS Demo Manager. Demos > add/open this demo (let it analyze):')
    [void]$manual.AppendLine("   $($script:S.Demo)")
    [void]$manual.AppendLine('2. Open the demo > Video tab. Settings: Recording system HLAE, Encoder FFmpeg, container mp4, codec libx264,')
    [void]$manual.AppendLine("   CRF 18, audio libmp3lame 256k, $($script:S.Width)x$($script:S.Height), Output = Video, Close the game when done = on,")
    [void]$manual.AppendLine('   TrueView off, X-Ray off. Framerate: as written for each pass below.')
    [void]$manual.AppendLine('3. For each sequence below: Add new sequence, type Start tick and End tick, add a Player camera')
    [void]$manual.AppendLine('   (tick + player), UNTICK "Player voices" (it turns itself back on every time!), tick "Show only death notices",')
    [void]$manual.AppendLine('   "Record audio" on, death notices 5 s, paste the CFG text into the CFG box, Save.')
    [void]$manual.AppendLine('4. Add to queue. Record the FIRST-PERSON pass first; when done, delete those sequences and add the CAMERA ones.')
    [void]$manual.AppendLine('')

    $prev = @()
    foreach ($c in $clips) {
        $cdir = Join-Path $run $c.Name
        $povDir = Join-Path $cdir 'pov'; New-Item -ItemType Directory -Force -Path $povDir | Out-Null
        $c.Dir = $cdir; $c.PovDir = $povDir
        $cl = New-Object Collections.Generic.List[string]
        $cl.Add('r_show_build_info 0')
        foreach ($n in $prev) { $cl.Add("mirv_streams remove $n") }   # stop the previous clip's layers from recording again
        foreach ($k in $script:S.Layers) { foreach ($ln in (New-LayerCfg "p$($c.N)" $k ($povDir -replace '\\', '/'))) { $cl.Add([string]$ln) }; $prev += "p$($c.N)$k" }
        $cfg = ($cl -join "`n")
        [IO.File]::WriteAllText((Join-Path $cdir 'pov_cfg.txt'), ($cl -join "`r`n"), $UTF8)
        $povSeq += [ordered]@{
            number = $c.N; startTick = $c.Start; endTick = $c.End
            showXRay = $false; showAssists = $true; showOnlyDeathNotices = $true
            playersOptions = @(); cameras = @()
            playerCameras = @([ordered]@{ tick = $c.Start; playerSteamId = [string]$p.steamid; playerName = [string]$p.name })
            playerVoicesEnabled = $false; recordAudio = $true; deathNoticesDuration = 5; cfg = $cfg
        }
        [void]$manual.AppendLine("---- FIRST-PERSON pass ($($script:S.Fps) fps) - $($c.Name)")
        [void]$manual.AppendLine("Start tick $($c.Start)   End tick $($c.End)   Player camera: tick $($c.Start) -> $($p.name)")
        [void]$manual.AppendLine('CFG:'); [void]$manual.AppendLine(($cl -join "`r`n")); [void]$manual.AppendLine('')
    }
    if ($script:S.CamOn) {
        $prev = @()
        foreach ($c in $clips) {
            $camDir = Join-Path $c.Dir 'cam'; New-Item -ItemType Directory -Force -Path $camDir | Out-Null
            $c.CamDir = $camDir
            $c.Anchor = $c.CamStart + 20
            $c.CamXml = Join-Path $c.Dir 'campath.xml'
            $cl = New-Object Collections.Generic.List[string]
            $cl.Add('r_show_build_info 0')
            foreach ($n in $prev) { $cl.Add("mirv_streams remove $n") }
            foreach ($k in $script:S.CamLayers) { foreach ($ln in (New-LayerCfg "c$($c.N)" $k ($camDir -replace '\\', '/'))) { $cl.Add([string]$ln) }; $prev += "c$($c.N)$k" }
            $cl.Add('mirv_cmd clear')
            $cl.Add('mirv_campath clear')
            $cl.Add('mirv_campath load "' + ($c.CamXml -replace '\\', '/') + '"')
            $cl.Add('mirv_campath enabled 1')
            $cl.Add('mirv_cmd enabled 1')
            $cl.Add("mirv_cmd addAtTick $($c.Anchor) mirv_campath edit start")
            foreach ($o in 22, 46, 80) { $cl.Add("mirv_cmd addAtTick $($c.CamStart + $o) spec_mode 4") }
            $cfg = ($cl -join "`n")
            [IO.File]::WriteAllText((Join-Path $c.Dir 'cam_cfg.txt'), ($cl -join "`r`n"), $UTF8)
            $camSeq += [ordered]@{
                number = $c.N; startTick = $c.CamStart; endTick = $c.CamEnd
                showXRay = $false; showAssists = $true; showOnlyDeathNotices = $true
                playersOptions = @(); cameras = @()
                playerCameras = @([ordered]@{ tick = ($c.CamStart + 40); playerSteamId = [string]$p.steamid; playerName = [string]$p.name })
                playerVoicesEnabled = $false; recordAudio = $true; deathNoticesDuration = 5; cfg = $cfg
            }
            [void]$manual.AppendLine("---- CAMERA pass ($($script:S.CamFps) fps) - $($c.Name)")
            [void]$manual.AppendLine("Start tick $($c.CamStart)   End tick $($c.CamEnd)   Player camera: tick $($c.CamStart + 40) -> $($p.name)")
            [void]$manual.AppendLine('CFG:'); [void]$manual.AppendLine(($cl -join "`r`n")); [void]$manual.AppendLine('')
        }
    }
    [IO.File]::WriteAllText((Join-Path $run 'MANUAL_STEPS.txt'), $manual.ToString(), $UTF8)
    $script:R.ManualFile = Join-Path $run 'MANUAL_STEPS.txt'

    $tp = Get-RecToolPaths
    $ffCustom = [bool]$tp.FfmpegCustom; $ffLoc = ''; if ($ffCustom) { $ffLoc = $tp.Ffmpeg }
    $ff = [ordered]@{ audioBitrate = 256; constantRateFactor = 18; customLocationEnabled = $ffCustom; customExecutableLocation = $ffLoc
                      videoContainer = 'mp4'; videoCodec = 'libx264'; audioCodec = 'libmp3lame'; inputParameters = ''; outputParameters = '' }
    $mkCfg = {
        param($seq, $fps, $outDir)
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        return [ordered]@{
            demoPath = $script:S.Demo; recordingSystem = 'HLAE'; recordingOutput = 'video'; encoderSoftware = 'FFmpeg'
            framerate = $fps; width = $script:S.Width; height = $script:S.Height
            closeGameAfterRecording = $true; trueView = $false; concatenateSequences = $false; outputFileName = ''
            ffmpegSettings = $ff; outputFolderPath = $outDir; sequences = @($seq)
        }
    }
    $script:R.PovCfg = Join-Path $run 'config_pov.json'
    Write-Json (& $mkCfg $povSeq $script:S.Fps (Join-Path $run 'csdm_pov')) $script:R.PovCfg
    if ($script:S.CamOn) {
        $script:R.CamCfg = Join-Path $run 'config_cam.json'
        Write-Json (& $mkCfg $camSeq $script:S.CamFps (Join-Path $run 'csdm_cam')) $script:R.CamCfg
    }
}
function Write-Json($obj, [string]$path) {
    $j = $obj | ConvertTo-Json -Depth 12
    # CSDM strips '#...' and '//...' as comments from its config file: make sure neither appears
    if ($j -match '#' -or $j -match '//') { throw "Generated config contains # or // which CS Demo Manager would misread. Use a simpler folder/demo path." }
    [IO.File]::WriteAllText($path, $j, $UTF8)
}
function RecSay([string]$t) { $script:RecLbl.Text = $t; $script:RecLog.AppendText("`r`n=== $t`r`n"); Log $t }

function Start-Recording {
    try { New-RunFiles } catch { Show-Error ("Could not prepare the files: " + $_.Exception.Message); return }
    $script:R.Recording = $true; $script:R.Failed = $false
    $script:BtnStart.Enabled = $false; $script:BtnCancel.Enabled = $true; Update-Nav
    $script:RecLog.Text = "Files prepared in $($script:R.RunDir)`r`n"
    $q = New-Object Collections.ArrayList
    [void]$q.Add(@{ Kind = 'analyze' })
    if ($script:S.CamOn) { foreach ($c in $script:R.RunClips) { [void]$q.Add(@{ Kind = 'campath'; Clip = $c }) } }
    [void]$q.Add(@{ Kind = 'csdm'; Cfg = $script:R.PovCfg; Label = 'first-person'; Log = (Join-Path $script:R.RunDir 'log_pov.txt') })
    if ($script:S.CamOn) { [void]$q.Add(@{ Kind = 'csdm'; Cfg = $script:R.CamCfg; Label = 'camera'; Log = (Join-Path $script:R.RunDir 'log_cam.txt') }) }
    [void]$q.Add(@{ Kind = 'verify' })
    $script:R.Queue = $q; $script:R.QTotal = $q.Count
    Next-RecStep
}
function Next-RecStep {
    if (-not $script:R.Recording) { return }
    if ($script:R.Queue.Count -eq 0) { return }
    $s = $script:R.Queue[0]; $script:R.Queue.RemoveAt(0)
    $n = $script:R.QTotal - $script:R.Queue.Count
    $csdm = Join-Path $script:R.Csdm 'csdm.cmd'
    switch ($s.Kind) {
        'analyze' {
            RecSay "Step $n/$($script:R.QTotal): CS Demo Manager reads the demo (once per demo, about a minute)"
            [void](Start-Bg ((Q $csdm) + ' analyze ' + (Q $script:S.Demo)) {
                param($o, $e, $code)
                $script:RecLog.AppendText((($o + $e) -replace "`r?`n", "`r`n"))
                if ($code -ne 0) { $script:RecLog.AppendText("`r`n(analysis reported a problem - continuing; the recording itself does not need it)`r`n") }
                Next-RecStep
            })
        }
        'campath' {
            $c = $s.Clip
            RecSay "Step $n/$($script:R.QTotal): computing the camera path for $($c.Name) (first one takes longest)"
            $argStr = 'campath ' + (Q $script:S.Demo) + ' ' + $script:R.Player.steamid + " $($c.Anchor) $($c.CamEnd) " + (Q $c.CamXml) +
                    " --fov $($script:S.Fov) --dist $($script:S.CamDist) --cache " + (Q (Join-Path $script:Data 'cache'))
            [void](Start-Bg (Helper $argStr) {
                param($o, $e, $code, $ctx)
                $r = Parse-Json $o $e
                if (-not $r.ok) { Fail-Rec "Camera path failed for $($ctx.Name): $($r.error)"; return }
                $msg = "Camera path OK: $($r.points) points, $($r.duration) s."
                if ($r.shortened -gt 0.3) { $msg += ' Tight space: the camera had to move closer often - check this shot for wall clipping.' }
                $script:RecLog.AppendText("$msg`r`n")
                Next-RecStep
            } $c)
        }
        'csdm' {
            RecSay "Step $n/$($script:R.QTotal): recording the $($s.Label) pass. CS2 opens now - hands off until it closes."
            $script:R.CurLog = $s.Log
            $script:R.StepStart = Get-Date; $script:R.InsecureOk = $false; $script:R.TickN = 0
            $script:OnTick = {
                $t = Read-All $script:R.CurLog
                if ($t -and $t.Length -ne $script:R.LastLen) { $script:R.LastLen = $t.Length; $script:RecLog.Text = ($t -replace "`r?`n", "`r`n"); $script:RecLog.SelectionStart = $script:RecLog.TextLength; $script:RecLog.ScrollToCaret() }
                if (-not $script:R.InsecureOk) { $script:R.TickN++; if ($script:R.TickN % 4 -eq 0) { Test-Insecure } }
            }
            [void](Start-Bg ((Q $csdm) + ' video --config-file ' + (Q $s.Cfg)) {
                param($o, $e, $code, $ctx)
                $script:OnTick = $null
                $txt = Read-All $ctx.Log
                if ($txt -notmatch 'Video generated in') {
                    Fail-Rec ("The $($ctx.Label) recording did not finish.`r`n`r`n" + (Get-Hint $txt) + "`r`n`r`nThe full log is in $($ctx.Log)")
                    return
                }
                Next-RecStep
            } $s $s.Log)
        }
        'verify' { RecSay 'Checking the files...'; Finish-Recording }
    }
}
function Test-Insecure {
    # Safety net: CS Demo Manager always adds -insecure itself. If a CS2 started during this step runs without it, stop at once.
    $ps = @(Get-CimInstance Win32_Process -Filter "Name='cs2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CreationDate -ge $script:R.StepStart })
    foreach ($p in $ps) {
        if (-not $p.CommandLine) { continue }
        if ($p.CommandLine -match '(?i)(^|\s)-insecure(\s|$)') {
            $script:R.InsecureOk = $true; Log "Safety check OK: CS2 runs with -insecure"; $script:RecLbl.Text += '   (safety check: -insecure OK)'; return
        }
        Log "SAFETY STOP: cs2 command line without -insecure: $($p.CommandLine)"
        Stop-AllJobs
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Get-Process hlae -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($script:R.Queue) { $script:R.Queue.Clear() }
        Fail-Rec ("SAFETY STOP: CS2 was started WITHOUT the -insecure launch option.`r`n`r`n" +
            "Recording tools (HLAE) must only run with -insecure, otherwise there is a VAC ban risk. The tool closed CS2 right away.`r`n`r`n" +
            "CS Demo Manager normally adds -insecure by itself, so this should not happen. Update CS Demo Manager and do not record until this is solved.")
        return
    }
}
function Get-Hint([string]$t) {
    if ($t -match '(?i)psql') { return 'PostgreSQL could not be used. Go back to "Check software".' }
    if ($t -match '(?i)raw files not found') { return 'CSDM found no recorded frames. Usually the game crashed or closed early. If CS2 crashed right when the demo was loading, the demo is from an older CS2 update and cannot be played now.' }
    if ($t -match '(?i)(crash|exited|closed)') { return 'CS2 closed unexpectedly. If it happened right when the demo was loading, the demo is from an older CS2 update and cannot be played now. Otherwise try again with "Test run" ticked.' }
    if ($t -match '(?i)steam') { return 'Steam problem: make sure Steam is open and signed in, then try again.' }
    if ($t -match '(?i)database|ECONNREFUSED|5432') { return 'The CSDM database (PostgreSQL) is not reachable. Restart the PC and run "Check software" again.' }
    $tail = ($t -split "`n" | Select-Object -Last 8) -join "`r`n"
    return "Last messages:`r`n$tail`r`n`r`nYou can try the Manual instructions button instead."
}
function Fail-Rec([string]$m) {
    $script:R.Recording = $false; $script:R.Failed = $true; $script:OnTick = $null
    $script:BtnCancel.Enabled = $false; Update-RecReady; Update-Nav
    RecSay 'Stopped because of a problem.'
    Show-Error $m
}
function Stop-Recording {
    if (-not (Ask-YesNo 'Stop the recording? CS2 will be closed.')) { return }
    $script:R.Recording = $false; $script:R.Queue.Clear()
    Stop-AllJobs
    Get-Process cs2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:OnTick = $null; $script:BtnCancel.Enabled = $false; Update-RecReady; Update-Nav
    RecSay 'Stopped by you. Files recorded so far are kept.'
}
function Open-Manual {
    if (-not $script:R.ManualFile -or -not (Test-Path $script:R.ManualFile)) { try { New-RunFiles } catch { Show-Error $_.Exception.Message; return } }
    Start-Process notepad.exe -ArgumentList (Q $script:R.ManualFile)
}
function Find-CsdmVideo([string]$sub, [int]$n) {
    # CSDM names its file sequence-<n>-tick-<start>-to-<end>.mp4; search subfolders too in case a version nests them
    $f = Get-ChildItem (Join-Path $script:R.RunDir $sub) -Recurse -File -Filter "sequence-$n-tick-*.mp4" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }; return $null
}
function Finish-Recording {
    $script:R.Recording = $false; $script:BtnCancel.Enabled = $false
    $sb = New-Object Text.StringBuilder
    $res = New-Object Text.StringBuilder
    $p = $script:R.Player
    [void]$res.AppendLine("CS2 Recorder result  $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    [void]$res.AppendLine("Demo: $($script:S.Demo)")
    [void]$res.AppendLine("Map: $($script:R.DemoInfo.map)   Player: $($p.name) ($($p.steamid))")
    [void]$res.AppendLine("Times below are seconds from the start of each file. 64 ticks = 1 second.")
    [void]$res.AppendLine('')
    $missing = 0; $okCount = 0
    foreach ($c in $script:R.RunClips) {
        [void]$res.AppendLine("== $($c.Name)  (round $($c.Round))")
        # move CSDM's own video next to the layers
        $src = Find-CsdmVideo 'csdm_pov' $c.N
        $dst = Join-Path $c.PovDir 'video_killfeed_audio.mp4'
        if ($src) { try { Move-Item -Force $src $dst } catch { $dst = $src } }
        $files = @($dst) + @($script:S.Layers | ForEach-Object { Get-ExpectedFile $c.PovDir $_ })
        [void]$res.AppendLine("  First-person files (start tick $($c.Start)):")
        foreach ($k in $c.Kills) {
            $tags = ''; if ($k.headshot) { $tags = ' HS' }
            [void]$res.AppendLine(('    kill at {0,6:N2} s  (tick {1})  {2} -> {3}{4}' -f (($k.tick - $c.Start) / $TICK), $k.tick, $k.weapon, $k.victim, $tags))
        }
        if ($script:S.CamOn) {
            $src = Find-CsdmVideo 'csdm_cam' $c.N
            $dstc = Join-Path $c.CamDir 'video_camera.mp4'
            if ($src) { try { Move-Item -Force $src $dstc } catch { $dstc = $src } }
            $files += @($dstc) + @($script:S.CamLayers | ForEach-Object { Get-ExpectedFile $c.CamDir $_ })
            [void]$res.AppendLine("  Camera files (start tick $($c.CamStart); usable from about {0:N2} s):" -f ((80 + 4) / $TICK))
            foreach ($k in $c.Kills) { [void]$res.AppendLine(('    kill at {0,6:N2} s  (tick {1})' -f (($k.tick - $c.CamStart) / $TICK), $k.tick)) }
        }
        foreach ($f in $files) {
            $ok = (Test-Path $f) -and ((Get-Item $f).Length -gt 50KB)
            if ($ok) { $okCount++ } else { $missing++ }
            $mark = 'MISSING'; if ($ok) { $mark = 'ok' }
            [void]$sb.AppendLine(('{0,-8} {1}' -f $mark, $f.Substring($script:R.RunDir.Length + 1)))
        }
        [void]$res.AppendLine('')
    }
    [void]$res.AppendLine('Editing notes:')
    [void]$res.AppendLine('- depth.mov looks almost black. That is normal: brighten/normalise it in your editor.')
    [void]$res.AppendLine('- players/viewModel/hud .mov files have transparency (ProRes 4444).')
    [void]$res.AppendLine('- The weapon cut-out also shows ejected bullet casings as small white dots.')
    [void]$res.AppendLine('- Camera shots: watch for the camera clipping through walls or objects.')
    [IO.File]::WriteAllText((Join-Path $script:R.RunDir 'RESULT.txt'), $res.ToString() + "`r`nFiles:`r`n" + $sb.ToString(), $UTF8)
    if ($missing -eq 0) { $head = "All $okCount files were recorded." } else { $head = "$okCount files OK, $missing MISSING. Missing layers usually mean CS2 closed early - try that clip again with Test run, or use the Manual instructions." }
    $script:R.ResultText = "$head`r`nFolder: $($script:R.RunDir)`r`n`r`n" + $sb.ToString()
    Log $script:R.ResultText
    Show-Page ($script:Pages.Count - 1)
}

# ------------------------------------------------------------------ sidebar + nav wiring
$yy = 70
foreach ($pg in $script:Pages) {
    $l = New-Object Windows.Forms.Label
    $l.Text = ('{0}. {1}' -f ($script:StepLabels.Count + 1), $pg.Title)
    $l.SetBounds(22, $yy, 190, 26); $l.ForeColor = $C_DIM
    $side.Controls.Add($l); $script:StepLabels += $l; $yy += 32
}
$btnNext.Add_Click({
    if ($script:Page -eq $script:Pages.Count - 1) { $form.Close(); return }
    $pg = $script:Pages[$script:Page]
    if ($pg.Next) { try { if (-not (& $pg.Next)) { return } } catch { Show-Error $_.Exception.Message; return } }
    Show-Page ($script:Page + 1)
})
$btnBack.Add_Click({ if ($script:Page -gt 0) { Show-Page ($script:Page - 1) } })
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:R.Recording -or $script:Jobs.Count -gt 0) {
        if (-not (Ask-YesNo 'Something is still running. Close anyway? (Running work will be stopped.)')) { $e.Cancel = $true; return }
        Stop-AllJobs
    }
    Save-State
})

$timer.Start()
Show-Page 0
[void]$form.ShowDialog()
$timer.Stop()
Log '--- wizard closed ---'
