# record.ps1 - GUI-free recording engine (port of wizard.ps1 recording logic).
# Dot-source it; nothing runs. Host calls Start-RecordRun, then Update-RecordRun about every second,
# and reads Get-RecordStatus. No Windows.Forms, never blocks.

$script:RecTick = 64
$script:RecUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:RR = $null

$script:RecLayers = @(
    @{ Key = 'clean'; Kind = 'h264' }, @{ Key = 'hud'; Kind = 'prores' }, @{ Key = 'depth'; Kind = 'depth' },
    @{ Key = 'depthNoEnts'; Kind = 'depth' }, @{ Key = 'players'; Kind = 'prores' }, @{ Key = 'viewModel'; Kind = 'prores' },
    @{ Key = 'world'; Kind = 'h264' }, @{ Key = 'particlesBlack'; Kind = 'h264' }, @{ Key = 'particlesWhite'; Kind = 'h264' }
)
function Get-RecLayer([string]$k) { foreach ($l in $script:RecLayers) { if ($l.Key -eq $k) { return $l } }; return $null }

function Get-RecProp($o, [string]$n, $default = $null) {
    if ($null -eq $o) { return $default }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] }; return $default }
    $p = $o.PSObject.Properties[$n]
    if ($p) { return $p.Value }
    return $default
}

function RecLog([string]$m) {
    if (-not $script:RR) { return }
    [void]$script:RR.Log.Add($m)
    try { Add-Content -Path (Join-Path $script:RR.DataDir 'record_log.txt') -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) -ErrorAction Stop } catch {}
}
function Q([string]$s) { return '"' + $s + '"' }

# ---- CFG text (HLAE mirv_streams)
function New-RecLayerCfg([string]$prefix, [string]$key, [string]$dirFwd) {
    $l = Get-RecLayer $key
    $st = $prefix + $key
    $pr = $prefix + 's' + $key
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
function Get-RecExpectedFile([string]$dir, [string]$key) {
    $l = Get-RecLayer $key; $ext = 'mp4'; if ($l.Kind -ne 'h264') { $ext = 'mov' }
    return (Join-Path $dir "$key.$ext")
}
function Test-RecSafePath([string]$p) {
    if ($p -match '[^\x20-\x7E]') { return 'The folder path has special letters. Pick a simple path like C:\cs2-recorder\recordings.' }
    if ($p -match '[#%"''&^]') { return 'The folder path contains one of these characters: # % " '' & ^ - pick a simpler path.' }
    if ($p -match '//') { return 'The folder path contains //. Pick a simple path.' }
    if ($p.Length -gt 120) { return 'The folder path is very long. Pick a shorter one.' }
    return $null
}

function Write-RecJson($obj, [string]$path) {
    $j = $obj | ConvertTo-Json -Depth 12
    # CSDM strips '#...' and '//...' as comments from its config file: make sure neither appears
    if ($j -match '#' -or $j -match '//') { throw "Generated config contains # or // which CS Demo Manager would misread. Use a simpler folder/demo path." }
    [IO.File]::WriteAllText($path, $j, $script:RecUtf8)
}

# ---- normalise clips from settings (fills N, Name, Round, CamStart, CamEnd)
function ConvertTo-RecClips($clips, $deaths) {
    $out = @(); $i = 0
    foreach ($src in @($clips)) {
        $i++
        $kills = @(Get-RecProp $src 'kills' @())
        $c = @{}
        $c.N = $i
        $c.Start = [int](Get-RecProp $src 'start'); $c.End = [int](Get-RecProp $src 'end')
        $c.Round = Get-RecProp $src 'round' 0
        if ($kills.Count -gt 0 -and $c.Round -eq 0) { $c.Round = Get-RecProp $kills[0] 'round' 0 }
        $c.Kills = $kills
        $c.Name = 'clip{0:D2}_r{1}_{2}k' -f $i, $c.Round, [Math]::Max(1, $kills.Count)
        $cs = Get-RecProp $src 'camStart'; if ($null -eq $cs) { $cs = [Math]::Max(192, $c.Start - $script:RecTick) }
        $c.CamStart = [int]$cs
        $ce = Get-RecProp $src 'camEnd'
        if ($null -eq $ce) {
            $ce = $c.End
            $last = $c.End; if ($kills.Count -gt 0) { $last = [int](Get-RecProp $kills[-1] 'tick' $c.End) }
            foreach ($d in @($deaths)) {
                $dt = [int](Get-RecProp $d 'tick' $d)
                if ($dt -gt $last -and $dt -lt $ce + 8) { $ce = [Math]::Min($ce, $dt - 8) }
            }
            if ($ce -le $last) { $ce = $last + 8 }
        }
        $c.CamEnd = [int]$ce
        $out += $c
    }
    return , $out
}

function Get-RecToolPaths {
    $app = Join-Path $env:USERPROFILE '.csdm'
    $r = @{ Hlae = (Join-Path $app 'hlae\hlae.exe'); Ffmpeg = (Join-Path $app 'ffmpeg\bin\ffmpeg.exe'); FfmpegCustom = $false }
    $f = Join-Path $app 'settings.json'
    if (Test-Path $f) {
        try {
            $s = Get-Content $f -Raw | ConvertFrom-Json
            $ff = $s.video.ffmpegSettings
            if ($ff -and $ff.customLocationEnabled -and $ff.customExecutableLocation) { $r.Ffmpeg = [string]$ff.customExecutableLocation; $r.FfmpegCustom = $true }
        } catch {}
    }
    return $r
}

# ---- run files: configs, cfg texts, MANUAL_STEPS.txt. Returns hashtable of paths.
function New-RecRunFiles($st, $clips) {
    $demoBase = [IO.Path]::GetFileNameWithoutExtension([string]$st.Demo)
    if ($demoBase.Length -gt 40) { $demoBase = $demoBase.Substring(0, 40) }
    $demoBase = $demoBase -replace '[^A-Za-z0-9_.-]', '_'
    $run = Join-Path $st.OutDir ('{0}_{1:yyyyMMdd-HHmm}' -f $demoBase, (Get-Date))
    New-Item -ItemType Directory -Force -Path $run | Out-Null
    $p = $st.Player
    $cam = $st.Camera
    $camOn = [bool](Get-RecProp $cam 'enabled' $false)
    $povSeq = @(); $camSeq = @(); $manual = New-Object Text.StringBuilder
    [void]$manual.AppendLine('MANUAL MODE - only if the automatic recording fails')
    [void]$manual.AppendLine('====================================================')
    [void]$manual.AppendLine('1. Open CS Demo Manager. Demos > add/open this demo (let it analyze):')
    [void]$manual.AppendLine("   $($st.Demo)")
    [void]$manual.AppendLine('2. Open the demo > Video tab. Settings: Recording system HLAE, Encoder FFmpeg, container mp4, codec libx264,')
    [void]$manual.AppendLine("   CRF 18, audio libmp3lame 256k, $($st.Width)x$($st.Height), Output = Video, Close the game when done = on,")
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
        foreach ($n in $prev) { $cl.Add("mirv_streams remove $n") }
        foreach ($k in $st.Layers) { foreach ($ln in (New-RecLayerCfg "p$($c.N)" $k ($povDir -replace '\\', '/'))) { $cl.Add([string]$ln) }; $prev += "p$($c.N)$k" }
        $cfg = ($cl -join "`n")
        [IO.File]::WriteAllText((Join-Path $cdir 'pov_cfg.txt'), ($cl -join "`r`n"), $script:RecUtf8)
        $povSeq += [ordered]@{
            number = $c.N; startTick = $c.Start; endTick = $c.End
            showXRay = $false; showAssists = $true; showOnlyDeathNotices = $true
            playersOptions = @(); cameras = @()
            playerCameras = @([ordered]@{ tick = $c.Start; playerSteamId = [string]$p.steamid; playerName = [string]$p.name })
            playerVoicesEnabled = $false; recordAudio = $true; deathNoticesDuration = 5; cfg = $cfg
        }
        [void]$manual.AppendLine("---- FIRST-PERSON pass ($($st.Fps) fps) - $($c.Name)")
        [void]$manual.AppendLine("Start tick $($c.Start)   End tick $($c.End)   Player camera: tick $($c.Start) -> $($p.name)")
        [void]$manual.AppendLine('CFG:'); [void]$manual.AppendLine(($cl -join "`r`n")); [void]$manual.AppendLine('')
    }
    $camLayers = @(Get-RecProp $cam 'layers' @())
    if ($camOn) {
        $prev = @()
        foreach ($c in $clips) {
            $camDir = Join-Path $c.Dir 'cam'; New-Item -ItemType Directory -Force -Path $camDir | Out-Null
            $c.CamDir = $camDir
            $c.Anchor = $c.CamStart + 20
            $c.CamXml = Join-Path $c.Dir 'campath.xml'
            $cl = New-Object Collections.Generic.List[string]
            $cl.Add('r_show_build_info 0')
            foreach ($n in $prev) { $cl.Add("mirv_streams remove $n") }
            foreach ($k in $camLayers) { foreach ($ln in (New-RecLayerCfg "c$($c.N)" $k ($camDir -replace '\\', '/'))) { $cl.Add([string]$ln) }; $prev += "c$($c.N)$k" }
            $cl.Add('mirv_cmd clear')
            $cl.Add('mirv_campath clear')
            $cl.Add('mirv_campath load "' + ($c.CamXml -replace '\\', '/') + '"')
            $cl.Add('mirv_campath enabled 1')
            $cl.Add('mirv_cmd enabled 1')
            $cl.Add("mirv_cmd addAtTick $($c.Anchor) mirv_campath edit start")
            foreach ($o in 22, 46, 80) { $cl.Add("mirv_cmd addAtTick $($c.CamStart + $o) spec_mode 4") }
            $cfg = ($cl -join "`n")
            [IO.File]::WriteAllText((Join-Path $c.Dir 'cam_cfg.txt'), ($cl -join "`r`n"), $script:RecUtf8)
            $camSeq += [ordered]@{
                number = $c.N; startTick = $c.CamStart; endTick = $c.CamEnd
                showXRay = $false; showAssists = $true; showOnlyDeathNotices = $true
                playersOptions = @(); cameras = @()
                playerCameras = @([ordered]@{ tick = ($c.CamStart + 40); playerSteamId = [string]$p.steamid; playerName = [string]$p.name })
                playerVoicesEnabled = $false; recordAudio = $true; deathNoticesDuration = 5; cfg = $cfg
            }
            [void]$manual.AppendLine("---- CAMERA pass ($(Get-RecProp $cam 'fps' 120) fps) - $($c.Name)")
            [void]$manual.AppendLine("Start tick $($c.CamStart)   End tick $($c.CamEnd)   Player camera: tick $($c.CamStart + 40) -> $($p.name)")
            [void]$manual.AppendLine('CFG:'); [void]$manual.AppendLine(($cl -join "`r`n")); [void]$manual.AppendLine('')
        }
    }
    [IO.File]::WriteAllText((Join-Path $run 'MANUAL_STEPS.txt'), $manual.ToString(), $script:RecUtf8)

    $tp = Get-RecToolPaths
    $ffCustom = [bool]$tp.FfmpegCustom; $ffLoc = ''; if ($ffCustom) { $ffLoc = $tp.Ffmpeg }
    $ff = [ordered]@{ audioBitrate = 256; constantRateFactor = 18; customLocationEnabled = $ffCustom; customExecutableLocation = $ffLoc
                      videoContainer = 'mp4'; videoCodec = 'libx264'; audioCodec = 'libmp3lame'; inputParameters = ''; outputParameters = '' }
    $mk = {
        param($seq, $fps, $outDir)
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        return [ordered]@{
            demoPath = $st.Demo; recordingSystem = 'HLAE'; recordingOutput = 'video'; encoderSoftware = 'FFmpeg'
            framerate = $fps; width = $st.Width; height = $st.Height
            closeGameAfterRecording = $true; trueView = $false; concatenateSequences = $false; outputFileName = ''
            ffmpegSettings = $ff; outputFolderPath = $outDir; sequences = @($seq)
        }
    }
    $paths = @{ RunDir = $run; ManualFile = (Join-Path $run 'MANUAL_STEPS.txt'); PovCfg = (Join-Path $run 'config_pov.json'); CamCfg = $null }
    Write-RecJson (& $mk $povSeq $st.Fps (Join-Path $run 'csdm_pov')) $paths.PovCfg
    if ($camOn) {
        $paths.CamCfg = Join-Path $run 'config_cam.json'
        Write-RecJson (& $mk $camSeq (Get-RecProp $cam 'fps' 120) (Join-Path $run 'csdm_cam')) $paths.CamCfg
    }
    return $paths
}

# ---- pure helpers
function Test-RecInsecureCmdLine([string]$cmd) { return ($cmd -match '(?i)(^|\s)-insecure(\s|$)') }
function Get-RecHint([string]$t) {
    if ($t -match '(?i)psql') { return 'PostgreSQL could not be used. Run the setup check again.' }
    if ($t -match '(?i)raw files not found') { return 'CSDM found no recorded frames. Usually the game crashed or closed early. If CS2 crashed right when the demo was loading, the demo is from an older CS2 update and cannot be played now.' }
    if ($t -match '(?i)(crash|exited|closed)') { return 'CS2 closed unexpectedly. If it happened right when the demo was loading, the demo is from an older CS2 update and cannot be played now. Otherwise try again with a test run.' }
    if ($t -match '(?i)steam') { return 'Steam problem: make sure Steam is open and signed in, then try again.' }
    if ($t -match '(?i)database|ECONNREFUSED|5432') { return 'The CSDM database (PostgreSQL) is not reachable. Restart the PC and run the setup check again.' }
    $tail = ($t -split "`n" | Select-Object -Last 8) -join "`r`n"
    return "Last messages:`r`n$tail`r`n`r`nYou can try MANUAL_STEPS.txt in the run folder instead."
}
function Read-RecFile([string]$f) {
    if (-not $f -or -not (Test-Path $f)) { return '' }
    try {
        $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); return $t
    } catch { return '' }
}

# ---- process control (no waiting)
function Start-RecBg([string]$command, [string]$logFile = '') {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $script:RR.DataDir "job_$id.out"; $err = Join-Path $script:RR.DataDir "job_$id.err"
    if ($logFile) { $redir = "> `"$logFile`" 2>&1"; $out = $logFile; $err = '' } else { $redir = "> `"$out`" 2> `"$err`"" }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = "/s /c `"$command $redir`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    RecLog "RUN: $command"
    return @{ P = [Diagnostics.Process]::Start($psi); Out = $out; Err = $err; Cmd = $command }
}
function Stop-RecJob {
    if ($script:RR -and $script:RR.Job) {
        try { & taskkill.exe /PID $script:RR.Job.P.Id /T /F 2>&1 | Out-Null } catch {}
        $script:RR.Job = $null
    }
}
function Set-RecFailed([string]$m) {
    $script:RR.State = 'failed'; $script:RR.Error = $m; $script:RR.Step = 'Stopped because of a problem.'
    $script:RR.Queue.Clear(); $script:RR.Job = $null
    RecLog "FAILED: $m"
}

function Test-RecInsecure {
    $rr = $script:RR
    $ps = @(Get-CimInstance Win32_Process -Filter "Name='cs2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CreationDate -ge $rr.StepStart })
    foreach ($p in $ps) {
        if (-not $p.CommandLine) { continue }
        if (Test-RecInsecureCmdLine $p.CommandLine) { $rr.InsecureOk = $true; RecLog 'Safety check OK: CS2 runs with -insecure'; return }
        RecLog "SAFETY STOP: cs2 command line without -insecure: $($p.CommandLine)"
        Stop-RecJob
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Get-Process hlae -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Set-RecFailed ("SAFETY STOP: CS2 was started WITHOUT the -insecure launch option.`r`n`r`n" +
            "Recording tools (HLAE) must only run with -insecure, otherwise there is a VAC ban risk. The tool closed CS2 right away.`r`n`r`n" +
            "CS Demo Manager normally adds -insecure by itself, so this should not happen. Update CS Demo Manager and do not record until this is solved.")
        return
    }
}

function Find-RecCsdmVideo([string]$sub, [int]$n) {
    $f = Get-ChildItem (Join-Path $script:RR.RunDir $sub) -Recurse -File -Filter "sequence-$n-tick-*.mp4" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }; return $null
}

function Complete-RecordRun {
    $rr = $script:RR; $st = $rr.Settings; $T = $script:RecTick
    $sb = New-Object Text.StringBuilder; $res = New-Object Text.StringBuilder
    $p = $st.Player; $camOn = $rr.CamOn
    [void]$res.AppendLine("CS2 Recorder result  $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    [void]$res.AppendLine("Demo: $($st.Demo)")
    [void]$res.AppendLine("Map: $(Get-RecProp $st 'Map' '')   Player: $($p.name) ($($p.steamid))")
    [void]$res.AppendLine('Times below are seconds from the start of each file. 64 ticks = 1 second.')
    [void]$res.AppendLine('')
    $missing = 0; $okCount = 0
    foreach ($c in $rr.RunClips) {
        [void]$res.AppendLine("== $($c.Name)  (round $($c.Round))")
        $src = Find-RecCsdmVideo 'csdm_pov' $c.N
        $dst = Join-Path $c.PovDir 'video_killfeed_audio.mp4'
        if ($src) { try { Move-Item -Force $src $dst } catch { $dst = $src } }
        $files = @($dst) + @($st.Layers | ForEach-Object { Get-RecExpectedFile $c.PovDir $_ })
        [void]$res.AppendLine("  First-person files (start tick $($c.Start)):")
        foreach ($k in $c.Kills) {
            $tags = ''; if (Get-RecProp $k 'headshot' $false) { $tags = ' HS' }
            $kt = [int](Get-RecProp $k 'tick' 0)
            [void]$res.AppendLine(('    kill at {0,6:N2} s  (tick {1})  {2} -> {3}{4}' -f (($kt - $c.Start) / $T), $kt, (Get-RecProp $k 'weapon' ''), (Get-RecProp $k 'victim' ''), $tags))
        }
        if ($camOn) {
            $src = Find-RecCsdmVideo 'csdm_cam' $c.N
            $dstc = Join-Path $c.CamDir 'video_camera.mp4'
            if ($src) { try { Move-Item -Force $src $dstc } catch { $dstc = $src } }
            $files += @($dstc) + @($rr.CamLayers | ForEach-Object { Get-RecExpectedFile $c.CamDir $_ })
            [void]$res.AppendLine("  Camera files (start tick $($c.CamStart); usable from about {0:N2} s):" -f ((80 + 4) / $T))
            foreach ($k in $c.Kills) { $kt = [int](Get-RecProp $k 'tick' 0); [void]$res.AppendLine(('    kill at {0,6:N2} s  (tick {1})' -f (($kt - $c.CamStart) / $T), $kt)) }
        }
        foreach ($f in $files) {
            $ok = (Test-Path $f) -and ((Get-Item $f).Length -gt 50KB)
            if ($ok) { $okCount++ } else { $missing++ }
            $mark = 'MISSING'; if ($ok) { $mark = 'ok' }
            [void]$sb.AppendLine(('{0,-8} {1}' -f $mark, $f.Substring($rr.RunDir.Length + 1)))
        }
        [void]$res.AppendLine('')
    }
    [void]$res.AppendLine('Editing notes:')
    [void]$res.AppendLine('- depth.mov looks almost black. That is normal: brighten/normalise it in your editor.')
    [void]$res.AppendLine('- players/viewModel/hud .mov files have transparency (ProRes 4444).')
    [void]$res.AppendLine('- The weapon cut-out also shows ejected bullet casings as small white dots.')
    [void]$res.AppendLine('- Camera shots: watch for the camera clipping through walls or objects.')
    [IO.File]::WriteAllText((Join-Path $rr.RunDir 'RESULT.txt'), $res.ToString() + "`r`nFiles:`r`n" + $sb.ToString(), $script:RecUtf8)
    if ($missing -eq 0) { $head = "All $okCount files were recorded." } else { $head = "$okCount files OK, $missing MISSING. Missing layers usually mean CS2 closed early - try that clip again as a test run, or use MANUAL_STEPS.txt." }
    $rr.ResultText = "$head`r`nFolder: $($rr.RunDir)`r`n`r`n" + $sb.ToString()
    $rr.State = 'done'; $rr.Step = 'Done.'; $rr.Pct = 100
    RecLog $rr.ResultText
}

function Start-RecNextStep {
    $rr = $script:RR
    if ($rr.State -ne 'running' -or $rr.Job) { return }
    if ($rr.Queue.Count -eq 0) { return }
    $s = $rr.Queue[0]; $rr.Queue.RemoveAt(0)
    $rr.Cur = $s; $rr.Tail = ''
    $n = $rr.QTotal - $rr.Queue.Count
    $rr.Pct = [int](100 * ($n - 1) / $rr.QTotal)
    $csdm = Join-Path $rr.Settings.CsdmDir 'csdm.cmd'
    $st = $rr.Settings
    switch ($s.Kind) {
        'analyze' {
            $rr.Step = "Step $n/$($rr.QTotal): CS Demo Manager reads the demo (once per demo, about a minute)"; RecLog $rr.Step
            $rr.Job = Start-RecBg ((Q $csdm) + ' analyze ' + (Q $st.Demo))
        }
        'campath' {
            $c = $s.Clip
            $rr.Step = "Step $n/$($rr.QTotal): computing the camera path for $($c.Name) (first one takes longest)"; RecLog $rr.Step
            $cam = $st.Camera
            $argStr = 'campath ' + (Q $st.Demo) + ' ' + $st.Player.steamid + " $($c.Anchor) $($c.CamEnd) " + (Q $c.CamXml) +
                " --fov $(Get-RecProp $cam 'fov' 50) --dist $(Get-RecProp $cam 'dist' 110) --cache " + (Q (Join-Path $st.DataDir 'cache'))
            $helper = (Q $rr.Py) + ' ' + (Q (Join-Path $st.ToolDir 'cs2tool.py')) + ' ' + $argStr
            $rr.Job = Start-RecBg $helper
        }
        'csdm' {
            $rr.Step = "Step $n/$($rr.QTotal): recording the $($s.Label) pass. CS2 opens now - hands off until it closes."; RecLog $rr.Step
            $rr.StepStart = Get-Date; $rr.InsecureOk = $false; $rr.TickN = 0; $rr.LastTick = [datetime]::MinValue
            $rr.Job = Start-RecBg ((Q $csdm) + ' video --config-file ' + (Q $s.Cfg)) $s.Log
        }
        'verify' { $rr.Step = 'Checking the files...'; RecLog $rr.Step; Complete-RecordRun }
    }
}

function Complete-RecJob {
    $rr = $script:RR; $j = $rr.Job; $s = $rr.Cur
    $rr.Job = $null
    $o = Read-RecFile $j.Out; $e = Read-RecFile $j.Err
    $code = $j.P.ExitCode
    RecLog ("DONE (exit {0}): {1}" -f $code, $j.Cmd)
    switch ($s.Kind) {
        'analyze' { if ($code -ne 0) { RecLog '(analysis reported a problem - continuing; the recording itself does not need it)' } }
        'campath' {
            $line = ($o -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
            $r = $null
            if ($line) { try { $r = $line | ConvertFrom-Json } catch {} }
            if (-not $r -or -not $r.ok) {
                $why = 'no answer from the helper'; if ($r) { $why = [string]$r.error } elseif ($e) { $why = $e.Trim() }
                Set-RecFailed "Camera path failed for $($s.Clip.Name): $why"; return
            }
            $msg = "Camera path OK: $($r.points) points, $($r.duration) s."
            if ($r.shortened -gt 0.3) { $msg += ' Tight space: the camera had to move closer often - check this shot for wall clipping.' }
            RecLog $msg
        }
        'csdm' {
            $txt = Read-RecFile $s.Log
            if ($txt -notmatch 'Video generated in') {
                Set-RecFailed ("The $($s.Label) recording did not finish.`r`n`r`n" + (Get-RecHint $txt) + "`r`n`r`nThe full log is in $($s.Log)"); return
            }
        }
    }
}

# ---- public API
function Start-RecordRun {
    param([hashtable]$Settings)
    if ($script:RR -and $script:RR.State -eq 'running') { throw 'A recording is already running.' }
    $st = $Settings
    $dataDir = $st.DataDir; if (-not $dataDir) { $dataDir = Join-Path $env:TEMP 'cs2rec' }
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $st.DataDir = $dataDir
    $script:RR = @{ State = 'running'; Step = 'Preparing files'; Pct = 0; Log = (New-Object Collections.ArrayList); ResultText = ''; RunDir = ''
                    Error = ''; InsecureOk = $false; Settings = $st; Queue = (New-Object Collections.ArrayList); Job = $null; Cur = $null; Tail = ''
                    DataDir = $dataDir; TickN = 0; LastTick = [datetime]::MinValue; StepStart = Get-Date; QTotal = 0 }
    try {
        $bad = Test-RecSafePath ([string]$st.OutDir); if ($bad) { throw $bad }
        $clips = ConvertTo-RecClips $st.Clips (Get-RecProp $st 'Deaths' @())
        if ($st.TestRun) { $clips = @($clips[0]) }
        $paths = New-RecRunFiles $st $clips
        $rr = $script:RR
        $rr.RunClips = $clips; $rr.RunDir = $paths.RunDir; $rr.ManualFile = $paths.ManualFile
        $rr.CamOn = [bool](Get-RecProp $st.Camera 'enabled' $false)
        $rr.CamLayers = @(Get-RecProp $st.Camera 'layers' @())
        $rr.Py = Get-RecProp $st 'HelperPy' ''
        RecLog "Files prepared in $($rr.RunDir)"
        $q = $rr.Queue
        [void]$q.Add(@{ Kind = 'analyze' })
        if ($rr.CamOn) { foreach ($c in $clips) { [void]$q.Add(@{ Kind = 'campath'; Clip = $c }) } }
        [void]$q.Add(@{ Kind = 'csdm'; Cfg = $paths.PovCfg; Label = 'first-person'; Log = (Join-Path $rr.RunDir 'log_pov.txt') })
        if ($rr.CamOn) { [void]$q.Add(@{ Kind = 'csdm'; Cfg = $paths.CamCfg; Label = 'camera'; Log = (Join-Path $rr.RunDir 'log_cam.txt') }) }
        [void]$q.Add(@{ Kind = 'verify' })
        $rr.QTotal = $q.Count
        Start-RecNextStep
    } catch { Set-RecFailed ("Could not prepare the files: " + $_.Exception.Message) }
}

function Update-RecordRun {
    $rr = $script:RR
    if (-not $rr -or $rr.State -ne 'running') { return }
    try {
        $j = $rr.Job
        if ($j) {
            if ($j.P.HasExited) { Complete-RecJob }
            elseif ($rr.Cur.Kind -eq 'csdm') {
                # kill-switch check every ~2 s, tracked by time so any host poll rate works
                if (-not $rr.InsecureOk -and ((Get-Date) - $rr.LastTick).TotalSeconds -ge 2) { $rr.LastTick = Get-Date; Test-RecInsecure }
                $rr.Tail = (Read-RecFile $rr.Cur.Log)
            }
        }
        if ($rr.State -eq 'running' -and -not $rr.Job) { Start-RecNextStep }
    } catch { Set-RecFailed ("Unexpected error: " + $_.Exception.Message) }
}

function Stop-RecordRun {
    $rr = $script:RR
    if (-not $rr -or $rr.State -ne 'running') { return }
    $rr.Queue.Clear(); Stop-RecJob
    Get-Process cs2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $rr.State = 'failed'; $rr.Error = 'Stopped by you. Files recorded so far are kept.'; $rr.Step = 'Stopped by you.'
    RecLog 'Stopped by user'
}

function Get-RecordStatus {
    $rr = $script:RR
    if (-not $rr) { return @{ state = 'idle'; step = ''; pct = 0; log = @(); resultText = ''; runDir = ''; error = ''; insecureOk = $false } }
    $lines = @($rr.Log)
    if ($rr.Tail) { $lines += @(($rr.Tail -split "`r?`n") | Where-Object { $_ }) }
    $lines = @($lines | Select-Object -Last 20)
    return @{ state = $rr.State; step = $rr.Step; pct = $rr.Pct; log = $lines; resultText = $rr.ResultText; runDir = $rr.RunDir; error = $rr.Error; insecureOk = $rr.InsecureOk }
}
