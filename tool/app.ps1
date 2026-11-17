# CS2 Recorder - local web app server. Started by START-NEW.bat. Windows PowerShell 5.1.
# Serves tool\ui on 127.0.0.1 (random port, per-run token) and opens it in an Edge/Chrome app window.
# All text in this file is plain ASCII on purpose.
param([switch]$NoWindow, [int]$Port = 0)

$ErrorActionPreference = 'Stop'
$script:Tool = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Base = Split-Path -Parent $script:Tool
$script:Data = Join-Path $script:Base 'data'
$script:Ui = Join-Path $script:Tool 'ui'
New-Item -ItemType Directory -Force -Path $script:Data | Out-Null
$script:LogFile = Join-Path $script:Data 'app.log'
$script:UTF8 = New-Object System.Text.UTF8Encoding($false)
function Log([string]$m) { try { Add-Content -Path $script:LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) } catch {} }
Log '--- app started ---'

# ------------------------------------------------------------------ optional libs (app degrades gracefully when missing)
$script:Libs = @{}
foreach ($n in 'setup', 'preflight', 'record') {
    $script:Libs[$n] = $false
    $f = Join-Path $script:Tool "lib\$n.ps1"
    if (Test-Path $f) {
        try { . $f; $script:Libs[$n] = $true } catch { Log "lib $n failed to load: $_" }
    }
}
function Test-Fn([string]$name) { return [bool](Get-Command $name -CommandType Function -ErrorAction SilentlyContinue) }
function Missing-Lib([string]$n) { return @{ ok = $false; error = "A part of the app is missing (tool\lib\$n.ps1). Re-download the CS2 Recorder folder or press Copy report and send it to the developer." } }

# ------------------------------------------------------------------ state
$script:Token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$script:Run = $true
$script:LastPing = Get-Date
$script:Seen = $false
$script:DialogOpen = $false
$script:Browser = $null
$script:BrowserStart = $null
$script:Jobs = @{}
$script:Sess = @{ Demo = ''; Info = $null; Kills = @(); Deaths = @(); Settings = $null }
$script:Setup = [hashtable]::Synchronized(@{ running = $false; pct = 0; msg = ''; done = $false; error = ''; checks = @() })
$script:SetupPs = $null
$script:VenvPy = Join-Path $script:Data 'pyenv\Scripts\python.exe'
$script:StateFile = Join-Path $script:Data 'state.json'
$TICK = 64

$LAYER_MB = @{ clean = 4; hud = 12; depth = 10; depthNoEnts = 10; players = 15; viewModel = 20; world = 4; particlesBlack = 2; particlesWhite = 2 }

# ------------------------------------------------------------------ helpers
function Read-Text([string]$f) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return '' }
    try {
        $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); return $t
    } catch { return '' }
}
function Get-SteamPath {
    try { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath; if ($p) { return ($p -replace '/', '\') } } catch {}
    foreach ($d in "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam") { if (Test-Path "$d\steam.exe") { return $d } }
    return $null
}
function Get-SteamAccounts([string]$steam) {
    $list = @()
    if (-not $steam) { return $list }
    $f = Join-Path $steam 'config\loginusers.vdf'
    if (-not (Test-Path $f)) { return $list }
    $txt = Get-Content $f -Raw
    foreach ($m in [regex]::Matches($txt, '"(\d{17})"\s*\{([^}]*)\}')) {
        $b = $m.Groups[2].Value
        $get = { param($k) $x = [regex]::Match($b, '(?i)"' + $k + '"\s*"([^"]*)"'); if ($x.Success) { $x.Groups[1].Value } else { '' } }
        $list += @{ id = $m.Groups[1].Value; account = (& $get 'AccountName'); persona = (& $get 'PersonaName'); recent = ((& $get 'MostRecent') -eq '1') }
    }
    return $list
}
function Test-SafePath([string]$p) {
    if (-not $p) { return 'Choose an output folder.' }
    if ($p -match '[^\x20-\x7E]') { return 'The folder path has special letters (accents or a, o with dots). Recording tools can break on them. Pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p -match '[#%"''&^]') { return 'The folder path contains one of these characters: # % " '' & ^ . Please pick a simpler path like C:\cs2-recorder\recordings.' }
    if ($p -match '//') { return 'The folder path contains //. Please pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p.Length -gt 120) { return 'The folder path is very long. Please pick a shorter one like C:\cs2-recorder\recordings.' }
    return $null
}
function Get-SizeMb([string[]]$keys, [int]$fps, [double]$seconds, [int]$w, [int]$h) {
    $scale = ([double]$w * [double]$h * $fps) / (1920.0 * 1080 * 60)
    $mb = 6
    foreach ($k in $keys) { if ($LAYER_MB.ContainsKey($k)) { $mb += $LAYER_MB[$k] } }
    return $mb * $scale * $seconds
}
function ToInt($v, [int]$def, [int]$min, [int]$max) {
    $n = $def
    try { $n = [int]$v } catch {}
    return [Math]::Max($min, [Math]::Min($max, $n))
}

# ------------------------------------------------------------------ settings + clips
function Get-Opts($b) {
    $layers = @(); if ($b.layers) { $layers = @($b.layers | ForEach-Object { [string]$_ } | Where-Object { $LAYER_MB.ContainsKey($_) }) }
    $camLayers = @(); if ($b.camLayers) { $camLayers = @($b.camLayers | ForEach-Object { [string]$_ } | Where-Object { $LAYER_MB.ContainsKey($_) }) }
    return @{
        Width = (ToInt $b.width 1920 320 7680); Height = (ToInt $b.height 1080 240 4320); Fps = (ToInt $b.fps 60 10 480)
        Layers = $layers; CamOn = [bool]$b.camOn; CamFps = (ToInt $b.camFps 120 10 480); Fov = (ToInt $b.fov 50 10 140)
        CamDist = (ToInt $b.camDist 110 20 400); CamLayers = $camLayers
        Before = (ToInt $b.before 4 0 30); After = (ToInt $b.after 2 0 30); Join = (ToInt $b.join 8 0 60)
        OutDir = [string]$b.outDir
    }
}
function Build-Clips($kills, $o) {
    $sel = @($kills | Sort-Object { [int]$_.tick })
    $clips = @(); $cur = $null
    foreach ($k in $sel) {
        $s = [int]($k.tick - $o.Before * $TICK); $e = [int]($k.tick + $o.After * $TICK)
        if ($cur -and $k.round -eq $cur.Round -and ($k.tick - $cur.Kills[-1].tick) -le $o.Join * $TICK) { $cur.Kills += $k; $cur.End = $e }
        elseif ($cur -and $s -le $cur.End + 128) { $cur.Kills += $k; $cur.End = $e }
        else {
            if ($cur) { $clips += $cur }
            $cur = @{ Round = $k.round; Kills = @($k); Start = [Math]::Max(192, $s); End = $e }
        }
    }
    if ($cur) { $clips += $cur }
    $i = 0
    foreach ($c in $clips) {
        $i++; $c.N = $i
        $c.Name = 'clip{0:D2}_r{1}_{2}k' -f $i, $c.Round, $c.Kills.Count
        $last = $c.Kills[-1].tick
        $c.CamStart = [Math]::Max(192, $c.Start - $TICK); $c.CamEnd = $c.End
        foreach ($d in @($script:Sess.Deaths)) { if ($d.tick -gt $last -and $d.tick -lt $c.CamEnd + 8) { $c.CamEnd = [Math]::Min($c.CamEnd, $d.tick - 8) } }
        if ($c.CamEnd -le $last) { $c.CamEnd = $last + 8 }
    }
    return , $clips
}
function Get-Selected($ticks) {
    $want = @{}; foreach ($t in @($ticks)) { $want[[int]$t] = $true }
    return @($script:Sess.Kills | Where-Object { $want.ContainsKey([int]$_.tick) })
}
function Get-Estimate($clips, $o) {
    $secs = 0.0; foreach ($c in $clips) { $secs += ($c.End - $c.Start) / $TICK }
    $mb = Get-SizeMb $o.Layers $o.Fps $secs $o.Width $o.Height
    $passes = 1; if ($o.CamOn) { $passes = 2 }
    $mins = [Math]::Round($clips.Count * 1.5 * $passes + 1, 0)
    $free = $null
    try { $free = [Math]::Round((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($o.OutDir))).AvailableFreeSpace / 1GB, 1) } catch {}
    $warn = @()
    if ($o.Layers.Count -eq 0) { $warn += 'Pick at least one layer to record.' }
    $bad = Test-SafePath $o.OutDir
    return @{ ok = $true; seconds = [Math]::Round($secs, 1); size_mb = [Math]::Round($mb, 0); size_gb = [Math]::Round($mb / 1024, 1); minutes = $mins; free_gb = $free; clips = $clips.Count; pathError = $bad; warnings = $warn }
}
function Clip-View($clips) {
    return @($clips | ForEach-Object { @{ n = $_.N; name = $_.Name; round = $_.Round; kills = $_.Kills.Count; seconds = [Math]::Round(($_.End - $_.Start) / $TICK, 1) } })
}

# ------------------------------------------------------------------ python helper jobs (never block the listener)
function Start-Py([string[]]$pyArgs, [scriptblock]$then = $null) {
    if (-not (Test-Path $script:VenvPy)) { return $null }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $job = @{ Id = $id; Proc = $null; Out = (Join-Path $script:Data "job_$id.out"); Err = (Join-Path $script:Data "job_$id.err"); Then = $then; Started = Get-Date; Result = $null }
    $script:Jobs[$id] = $job
    Start-PyProc $job $pyArgs
    return $job
}
function Start-PyProc($job, [string[]]$pyArgs) {
    $q = ($pyArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $env:PYTHONIOENCODING = 'utf-8'
    Log ("RUN: python " + $q)
    $job.Proc = Start-Process -FilePath $script:VenvPy -ArgumentList $q -RedirectStandardOutput $job.Out -RedirectStandardError $job.Err -WindowStyle Hidden -PassThru
    $job.Started = Get-Date
}
function Parse-JobOutput($job) {
    $o = Read-Text $job.Out; $e = Read-Text $job.Err
    $line = ($o -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { return @{ ok = $false; error = 'The demo reader gave no answer. Press Copy report if this keeps happening.'; detail = $e.Trim() } }
    try { return ($line | ConvertFrom-Json) } catch { return @{ ok = $false; error = 'The demo reader gave an unreadable answer.'; detail = $line } }
}
function Poll-Job([string]$id) {
    $job = $script:Jobs[$id]
    if (-not $job) { return @{ ok = $false; done = $true; error = 'Unknown job.' } }
    if ($job.Result) { return $job.Result }
    if (-not $job.Proc.HasExited) {
        if (((Get-Date) - $job.Started).TotalMinutes -gt 10) {
            try { & taskkill.exe /PID $job.Proc.Id /T /F 2>&1 | Out-Null } catch {}
            $job.Result = @{ ok = $false; done = $true; error = 'Reading the demo took too long and was stopped.' }
            return $job.Result
        }
        return @{ ok = $true; done = $false }
    }
    $r = Parse-JobOutput $job
    if ($job.Then -and $r.ok) {
        $next = & $job.Then $r $job      # may start another process on the same job
        if ($next -eq 'continue') { return @{ ok = $true; done = $false } }
        $r = $next
    }
    $res = @{ done = $true }
    if ($r -is [hashtable]) { foreach ($k in $r.Keys) { $res[$k] = $r[$k] } } else { foreach ($p in $r.PSObject.Properties) { $res[$p.Name] = $p.Value } }
    $job.Result = $res
    Remove-Item $job.Out, $job.Err -Force -ErrorAction SilentlyContinue
    return $res
}
function Stop-AllJobs {
    foreach ($j in @($script:Jobs.Values)) { try { if ($j.Proc -and -not $j.Proc.HasExited) { & taskkill.exe /PID $j.Proc.Id /T /F 2>&1 | Out-Null } } catch {} }
}

# ------------------------------------------------------------------ setup (background runspace)
function Start-SetupRun($fixId) {
    if ($script:Setup.running) { return @{ ok = $true; running = $true } }
    if (-not $script:Libs.setup) { return (Missing-Lib 'setup') }
    $script:Setup.running = $true; $script:Setup.done = $false; $script:Setup.pct = 0; $script:Setup.msg = 'Starting...'; $script:Setup.error = ''
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Setup)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($lib, $fixId)
        $ErrorActionPreference = 'Stop'
        try {
            . $lib
            $cb = { param($pct, $msg) $sync.pct = $pct; $sync.msg = [string]$msg }
            if ($fixId) {
                $r = Invoke-SetupFix -Id $fixId -OnProgress $cb
                if ($r -and -not $r.ok) { $sync.error = [string]$r.message }
                $sync.checks = @(Get-SetupCheck | ForEach-Object { $_ })
            } else {
                $sync.checks = @(Invoke-SetupAll -OnProgress $cb | ForEach-Object { $_ })
            }
        } catch { $sync.error = 'Setup stopped: ' + $_.Exception.Message }
        $sync.pct = 100; $sync.running = $false; $sync.done = $true
    }).AddArgument((Join-Path $script:Tool 'lib\setup.ps1')).AddArgument($fixId)
    $script:SetupPs = $ps
    [void]$ps.BeginInvoke()
    return @{ ok = $true; running = $true }
}
function Get-CheckResult {
    if (-not $script:Libs.setup) { return (Missing-Lib 'setup') }
    try {
        $c = @(Get-SetupCheck | ForEach-Object { $_ })
        $all = (@($c | Where-Object { $_.status -ne 'ok' }).Count -eq 0)
        return @{ ok = $true; checks = $c; allOk = $all }
    } catch { Log "check failed: $_"; return @{ ok = $false; error = 'The system check failed: ' + $_.Exception.Message } }
}

# ------------------------------------------------------------------ dialogs (STA main thread)
function Show-Browse([string]$kind, [string]$start) {
    Add-Type -AssemblyName System.Windows.Forms
    $script:DialogOpen = $true
    try {
        $owner = New-Object Windows.Forms.Form; $owner.TopMost = $true; $owner.ShowInTaskbar = $false
        $owner.StartPosition = 'CenterScreen'; $owner.Size = New-Object Drawing.Size(1, 1); $owner.Opacity = 0; $owner.Show()
        if ($kind -eq 'folder') {
            $d = New-Object Windows.Forms.FolderBrowserDialog; $d.Description = 'Choose the folder for recordings'
            if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
            if ($d.ShowDialog($owner) -eq 'OK') { return @{ ok = $true; path = $d.SelectedPath } }
        } else {
            $d = New-Object Windows.Forms.OpenFileDialog; $d.Title = 'Choose a CS2 demo'
            $d.Filter = 'CS2 demos (*.dem;*.zst;*.bz2;*.gz)|*.dem;*.zst;*.bz2;*.gz|All files (*.*)|*.*'
            if ($d.ShowDialog($owner) -eq 'OK') { return @{ ok = $true; path = $d.FileName } }
        }
        return @{ ok = $true; path = '' }
    } catch { return @{ ok = $false; error = 'Could not open the file window: ' + $_.Exception.Message } }
    finally { try { $owner.Close() } catch {}; $script:DialogOpen = $false; $script:LastPing = Get-Date }
}
function Find-DemoByName([string]$name) {
    $name = [IO.Path]::GetFileName($name)
    if (-not $name) { return @() }
    $roots = @()
    foreach ($r in [Environment]::GetFolderPath('UserProfile') + '\Downloads', [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), $script:Base) { if ($r -and (Test-Path $r)) { $roots += $r } }
    $st = Get-SteamPath
    if ($st) { $roots += (Join-Path $st 'steamapps\common\Counter-Strike Global Offensive\game\csgo') }
    $found = @()
    foreach ($r in $roots) {
        try { $found += @(Get-ChildItem -LiteralPath $r -Filter $name -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { $_.FullName }) } catch {}
        if ($found.Count -ge 5) { break }
    }
    return @($found | Select-Object -Unique)
}

# ------------------------------------------------------------------ report (logs with the Windows user name hidden)
function Get-RedactedLogs {
    $sb = New-Object Text.StringBuilder
    foreach ($n in 'app.log', 'wizard.log', 'setup.log', 'record.log') {
        $f = Join-Path $script:Data $n
        if (Test-Path $f) {
            $t = Read-Text $f
            if ($t.Length -gt 60000) { $t = $t.Substring($t.Length - 60000) }
            [void]$sb.AppendLine("===== $n =====")
            [void]$sb.AppendLine($t)
        }
    }
    $s = $sb.ToString()
    foreach ($u in $env:USERNAME, (Split-Path -Leaf $env:USERPROFILE)) { if ($u) { $s = [regex]::Replace($s, [regex]::Escape($u), 'USER', 'IgnoreCase') } }
    return $s
}

# ------------------------------------------------------------------ API
function Invoke-Api([string]$method, [string]$path, $q, $b) {
    switch ("$method $path") {
        'GET /api/ping' { return @{ ok = $true; libs = $script:Libs } }
        'POST /api/quit' { $script:Run = $false; return @{ ok = $true } }
        'GET /api/check' { return (Get-CheckResult) }
        'POST /api/setup/start' { return (Start-SetupRun ([string]$b.fixId)) }
        'GET /api/setup/status' {
            $s = $script:Setup
            return @{ ok = $true; running = $s.running; pct = $s.pct; msg = $s.msg; done = $s.done; error = $s.error; checks = @($s.checks) }
        }
        'GET /api/accounts' {
            $st = Get-SteamPath
            return @{ ok = $true; steam = $st; accounts = @(Get-SteamAccounts $st) }
        }
        'GET /api/state' { try { if (Test-Path $script:StateFile) { return @{ ok = $true; state = (Get-Content $script:StateFile -Raw | ConvertFrom-Json) } } } catch {}; return @{ ok = $true; state = $null } }
        'POST /api/state' {
            try { [IO.File]::WriteAllText($script:StateFile, ($b.state | ConvertTo-Json -Depth 6), $script:UTF8) } catch { Log "state save failed: $_" }
            return @{ ok = $true }
        }
        'POST /api/browse' { return (Show-Browse ([string]$b.kind) ([string]$b.start)) }
        'POST /api/find' { return @{ ok = $true; paths = @(Find-DemoByName ([string]$b.name)) } }
        'GET /api/job' { return (Poll-Job ([string]$q['id'])) }
        'POST /api/demo' {
            $p = [string]$b.path
            $p = $p.Trim().Trim('"')
            if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ ok = $false; error = "I can not find that file. Use Browse, or paste the full path (for example C:\Users\you\Downloads\match.dem)." } }
            if (-not (Test-Path $script:VenvPy)) { return @{ ok = $false; error = 'The demo reader is not installed yet. Go back to step 1 and press Set up.' } }
            $then = { param($r, $job)
                $job.Then = $null
                if ($r.path -and $job.Stage -eq 'decompress') {
                    $script:Sess.Demo = [string]$r.path; $job.Stage = 'info'
                    Start-PyProc $job @((Join-Path $script:Tool 'cs2tool.py'), 'info', [string]$r.path)
                    $job.Then = { param($r2, $job2) $job2.Then = $null; $script:Sess.Info = $r2; return (Demo-View $r2) }
                    return 'continue'
                }
                return $r
            }
            $tool = Join-Path $script:Tool 'cs2tool.py'
            $script:Sess.Kills = @(); $script:Sess.Deaths = @()
            if ($p -match '\.dem$') {
                $script:Sess.Demo = $p
                $job = Start-Py @($tool, 'info', $p) { param($r, $job) $job.Then = $null; $script:Sess.Info = $r; return (Demo-View $r) }
            } else {
                $dir = Join-Path $script:Data 'demos'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $dst = Join-Path $dir (([IO.Path]::GetFileNameWithoutExtension($p) -replace '\.dem$', '') + '.dem')
                $job = Start-Py @($tool, 'decompress', $p, $dst) $then
                if ($job) { $job.Stage = 'decompress' }
            }
            if (-not $job) { return @{ ok = $false; error = 'The demo reader is not installed yet.' } }
            return @{ ok = $true; job = $job.Id }
        }
        'POST /api/kills' {
            if (-not $script:Sess.Demo) { return @{ ok = $false; error = 'Pick a demo first.' } }
            $sid = [string]$b.steamid
            if ($sid -notmatch '^\d{5,20}$') { return @{ ok = $false; error = 'Pick a player first.' } }
            $job = Start-Py @((Join-Path $script:Tool 'cs2tool.py'), 'kills', $script:Sess.Demo, $sid) {
                param($r, $job) $job.Then = $null
                $script:Sess.Kills = @($r.kills); $script:Sess.Deaths = @($r.deaths)
                return @{ ok = $true; kills = @($r.kills) }
            }
            if (-not $job) { return @{ ok = $false; error = 'The demo reader is not installed yet.' } }
            return @{ ok = $true; job = $job.Id }
        }
        'POST /api/presets' {
            $sid = [string]$b.steamid
            if ($sid -notmatch '^\d{5,20}$' -or -not $script:Sess.Demo) { return @{ ok = $false; error = 'Pick a demo and player first.' } }
            $job = Start-Py @((Join-Path $script:Tool 'cs2tool.py'), 'presets', '--demo', $script:Sess.Demo, '--player', $sid)
            if (-not $job) { return @{ ok = $false; error = 'The demo reader is not installed yet.' } }
            return @{ ok = $true; job = $job.Id }
        }
        'POST /api/clips' {
            $o = Get-Opts $b
            $clips = Build-Clips (Get-Selected $b.ticks) $o
            return @{ ok = $true; clips = (Clip-View $clips) }
        }
        'POST /api/estimate' {
            $o = Get-Opts $b
            $clips = Build-Clips (Get-Selected $b.ticks) $o
            return (Get-Estimate $clips $o)
        }
        'POST /api/preflight' {
            if (-not $script:Libs.preflight -or -not (Test-Fn 'Get-Preflight')) { return (Missing-Lib 'preflight') }
            $o = Get-Opts $b
            try {
                $pa = @{ AccountId = [string]$b.accountId; AccountKind = [string]$b.accountKind; DemoInfo = $script:Sess.Info }
                $cp = (Get-Command Get-Preflight).Parameters
                if ($cp.ContainsKey('OutDir')) { $pa.OutDir = $o.OutDir }
                if ($cp.ContainsKey('SteamPath')) { $pa.SteamPath = (Get-SteamPath) }
                $r = Get-Preflight @pa
                return @{ ok = $true; blocking = [bool]$r.blocking; checks = @($r.checks) }
            } catch { Log "preflight failed: $_"; return @{ ok = $false; error = 'The safety checks could not run: ' + $_.Exception.Message } }
        }
        'POST /api/graphics/fix' {
            if (-not $script:Libs.preflight -or -not (Test-Fn 'Set-GraphicsFix')) { return (Missing-Lib 'preflight') }
            if ([string]$b.accountKind -ne 'separate') { return @{ ok = $false; error = 'Settings are only changed on your separate recording account.' } }
            try { $r = Set-GraphicsFix -SteamPath (Get-SteamPath) -AccountId ([string]$b.accountId) } catch { Log "graphics fix failed: $_"; return @{ ok = $false; error = 'Could not change the graphics settings: ' + $_.Exception.Message } }
            Log "graphics fix: ok=$($r.ok) $($r.message)"
            if (-not $r.ok) { return @{ ok = $false; error = [string]$r.message } }
            return @{ ok = $true; message = [string]$r.message; changed = @($r.changed) }
        }
        'POST /api/record/start' {
            if (-not $script:Libs.record -or -not (Test-Fn 'Start-RecordRun')) { return (Missing-Lib 'record') }
            if (-not $script:Sess.Demo -or $script:Sess.Kills.Count -eq 0) { return @{ ok = $false; error = 'Pick a demo, a player and some kills first.' } }
            $o = Get-Opts $b
            if ($b.accountKind -ne 'separate') { return @{ ok = $false; error = 'Recording on your main Steam account is blocked. Use a separate account.' } }
            $bad = Test-SafePath $o.OutDir
            if ($bad) { return @{ ok = $false; error = $bad } }
            if ($o.Layers.Count -eq 0) { return @{ ok = $false; error = 'Pick at least one layer to record.' } }
            $clips = Build-Clips (Get-Selected $b.ticks) $o
            if ($clips.Count -eq 0) { return @{ ok = $false; error = 'No kills are selected.' } }
            $settings = @{
                Demo = $script:Sess.Demo; DemoInfo = $script:Sess.Info; PlayerId = [string]$b.steamid; PlayerName = [string]$b.playerName
                AccountId = [string]$b.accountId; AccountKind = [string]$b.accountKind; SteamPath = (Get-SteamPath)
                Clips = $clips; Deaths = @($script:Sess.Deaths); Tool = $script:Tool; Base = $script:Base; Data = $script:Data; Python = $script:VenvPy
            }
            foreach ($k in $o.Keys) { $settings[$k] = $o[$k] }
            # keys exactly as lib/record.ps1 expects them
            $csdmDir = ''; if (Test-Fn 'Get-CsdmDir') { $csdmDir = [string](Get-CsdmDir) }
            if (-not $csdmDir) { return @{ ok = $false; error = 'CS Demo Manager was not found. Go back to step 1 and press Set up.' } }
            $settings.Player = @{ steamid = [string]$b.steamid; name = [string]$b.playerName }
            $settings.Camera = @{ enabled = [bool]$o.CamOn; fov = $o.Fov; dist = $o.CamDist; fps = $o.CamFps; layers = @($o.CamLayers) }
            $settings.HelperPy = $script:VenvPy; $settings.CsdmDir = $csdmDir
            $settings.ToolDir = $script:Tool; $settings.DataDir = $script:Data
            $settings.Map = [string]$script:Sess.Info.map
            $settings.TestRun = [bool]$b.testRun
            $script:Sess.Settings = $settings
            try { $r = Start-RecordRun -Settings $settings } catch { Log "record start failed: $_"; return @{ ok = $false; error = 'Could not start recording: ' + $_.Exception.Message } }
            if ($r -is [hashtable] -or $r -is [pscustomobject]) { if ($null -ne $r.ok -and -not $r.ok) { return @{ ok = $false; error = [string]$(if ($r.error) { $r.error } else { $r.message }) } } }
            return @{ ok = $true }
        }
        'GET /api/record/status' {
            if (-not $script:Libs.record -or -not (Test-Fn 'Get-RecordStatus')) { return (Missing-Lib 'record') }
            try {
                if (Test-Fn 'Update-RecordRun') { Update-RecordRun }
                $s = Get-RecordStatus
                $out = @{ ok = $true; status = $s }
                if ($script:Sess.Settings) { $out.outDir = $script:Sess.Settings.OutDir }
                return $out
            } catch { Log "record status failed: $_"; return @{ ok = $false; error = 'Could not read the recording status: ' + $_.Exception.Message } }
        }
        'POST /api/record/stop' {
            if (-not $script:Libs.record -or -not (Test-Fn 'Stop-RecordRun')) { return (Missing-Lib 'record') }
            try { Stop-RecordRun | Out-Null; return @{ ok = $true } } catch { return @{ ok = $false; error = 'Could not stop: ' + $_.Exception.Message } }
        }
        'POST /api/open' {
            $dir = ''; if ($script:Sess.Settings) { $dir = [string]$script:Sess.Settings.OutDir }
            if (-not $dir -and $b.dir) { $dir = [string]$b.dir }
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @{ ok = $false; error = 'The recordings folder does not exist yet.' } }
            if ($b.what -eq 'result') {
                $f = Get-ChildItem -LiteralPath $dir -Filter 'RESULT.txt' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $f) { return @{ ok = $false; error = 'No RESULT.txt found yet.' } }
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $f.FullName + '"'); return @{ ok = $true }
            }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"'); return @{ ok = $true }
        }
        'GET /api/report' {
            if ($q['format'] -eq 'text') { return @{ ok = $true; text = (Get-RedactedLogs) } }
            return @{ ok = $true; zip = $true }
        }
        default { return @{ ok = $false; error = 'Unknown request.'; status = 404 } }
    }
}
function Demo-View($r) {
    if (-not $r.ok) { return $r }
    $hdr = $null; if ($r.header) { $hdr = $r.header }
    return @{ ok = $true; map = $r.map; players = @($r.players); tickrate = $r.tickrate; header = $hdr; file = [IO.Path]::GetFileName([string]$script:Sess.Demo) }
}

# ------------------------------------------------------------------ http plumbing
$MIME = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'; '.txt' = 'text/plain; charset=utf-8' }
function Send-Bytes($res, [int]$code, [byte[]]$bytes, [string]$ctype) {
    $res.StatusCode = $code; $res.ContentType = $ctype
    $res.Headers.Add('Cache-Control', 'no-store'); $res.Headers.Add('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.OutputStream.Close()
}
function Send-Json($res, [int]$code, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Bytes $res $code ($script:UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}
function Send-Static($res, [string]$path) {
    if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
    $rel = [Uri]::UnescapeDataString($path).TrimStart('/').Replace('/', '\')
    if ($rel -match '\.\.' -or $rel -match '[:<>"|?*]' -or $rel.StartsWith('\')) { Send-Bytes $res 403 ($script:UTF8.GetBytes('Forbidden')) 'text/plain'; return }
    $root = [IO.Path]::GetFullPath($script:Ui).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $script:Ui $rel))
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Send-Bytes $res 403 ($script:UTF8.GetBytes('Forbidden')) 'text/plain'; return }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Send-Bytes $res 404 ($script:UTF8.GetBytes('Not found')) 'text/plain'; return }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $ct = $MIME[$ext]; if (-not $ct) { $ct = 'application/octet-stream' }
    if ($ext -eq '.html') {
        $t = [IO.File]::ReadAllText($full, $script:UTF8).Replace('__TOKEN__', $script:Token)
        Send-Bytes $res 200 ($script:UTF8.GetBytes($t)) $ct
    } else { Send-Bytes $res 200 ([IO.File]::ReadAllBytes($full)) $ct }
}
function Handle-Request($ctx) {
    $req = $ctx.Request; $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    if ($req.Url.Host -ne '127.0.0.1') { Send-Bytes $res 403 ($script:UTF8.GetBytes('Forbidden')) 'text/plain'; return }
    if ($path.StartsWith('/api/')) {
        if ($req.Headers['X-Token'] -ne $script:Token) { Send-Json $res 403 @{ ok = $false; error = 'Forbidden' }; return }
        $script:LastPing = Get-Date; $script:Seen = $true
        $b = $null
        if ($req.HttpMethod -eq 'POST' -and $req.HasEntityBody) {
            $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $raw = $sr.ReadToEnd(); $sr.Close()
            if ($raw) { try { $b = $raw | ConvertFrom-Json } catch { Send-Json $res 400 @{ ok = $false; error = 'Bad request.' }; return } }
        }
        if ($null -eq $b) { $b = [pscustomobject]@{} }
        $q = @{}
        foreach ($k in $req.QueryString.AllKeys) { if ($k) { $q[$k] = $req.QueryString[$k] } }
        try { $r = Invoke-Api $req.HttpMethod $path $q $b }
        catch { Log ("API error $path : " + $_.Exception.Message + "`n" + $_.ScriptStackTrace); $r = @{ ok = $false; error = 'Something went wrong inside the app. Press Copy report and send it to the developer.' } }
        if ($path -eq '/api/report' -and $r.zip) { Send-Report $res; return }
        $code = 200; if ($r -is [hashtable] -and $r.status) { $code = [int]$r.status; $r.Remove('status') }
        Send-Json $res $code $r
        return
    }
    if ($req.HttpMethod -ne 'GET') { Send-Bytes $res 405 ($script:UTF8.GetBytes('Method not allowed')) 'text/plain'; return }
    Send-Static $res $path
}
function Send-Report($res) {
    $tmp = Join-Path $env:TEMP ('cs2rec_report_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $tmp 'logs.txt'), (Get-RedactedLogs), $script:UTF8)
        $zip = Join-Path $env:TEMP ('cs2rec_report_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
        Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
        $bytes = [IO.File]::ReadAllBytes($zip)
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $res.Headers.Add('Content-Disposition', 'attachment; filename="cs2-recorder-report.zip"')
        Send-Bytes $res 200 $bytes 'application/zip'
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ start
if ($Port -le 0) {
    $tl = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tl.Start()
    $Port = $tl.LocalEndpoint.Port; $tl.Stop()
}
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { Log "listener failed: $_"; Write-Host "Could not start the local server on port $Port : $($_.Exception.Message)"; exit 2 }
$url = "http://127.0.0.1:$Port/"
Log "listening on $url"
Write-Host "CS2 Recorder is running at $url"
if ($NoWindow) { Write-Host "TOKEN=$($script:Token)" }

function Find-Browser {
    $c = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
if (-not $NoWindow) {
    $exe = Find-Browser
    if ($exe) {
        $prof = Join-Path $script:Data 'browser-profile'
        $script:Browser = Start-Process -FilePath $exe -ArgumentList @("--app=$url", "--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', '--window-size=1100,820') -PassThru
        $script:BrowserStart = Get-Date
    } else { Start-Process $url }
}
$script:StartedAt = Get-Date

function Test-Idle {
    if ($NoWindow) { return $false }
    if ($script:DialogOpen) { return $false }
    $now = Get-Date
    if ($script:Browser -and $script:Browser.HasExited -and (($now - $script:BrowserStart).TotalSeconds -gt 10)) { return $true }
    if ($script:Seen -and (($now - $script:LastPing).TotalSeconds -gt 30)) { return $true }
    if (-not $script:Seen -and (($now - $script:StartedAt).TotalSeconds -gt 120)) { return $true }
    return $false
}

try {
    while ($script:Run) {
        $t = $listener.GetContextAsync()
        while (-not $t.Wait(300)) {
            if (-not $script:Run -or (Test-Idle)) { $script:Run = $false; break }
        }
        if (-not $script:Run) { break }
        $ctx = $t.Result
        try { Handle-Request $ctx }
        catch { Log ("request error: " + $_.Exception.Message); try { $ctx.Response.Abort() } catch {} }
    }
} finally {
    Log 'shutting down'
    try { if ($script:Libs.record -and (Test-Fn 'Stop-RecordRun')) { Stop-RecordRun | Out-Null } } catch {}
    Stop-AllJobs
    try { if ($script:SetupPs) { $script:SetupPs.Stop() } } catch {}
    try { $listener.Stop(); $listener.Close() } catch {}
    try { if ($script:Browser -and -not $script:Browser.HasExited) { $script:Browser.CloseMainWindow() | Out-Null } } catch {}
}
