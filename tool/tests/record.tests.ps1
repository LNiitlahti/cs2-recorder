# Plain test script for tool/lib/record.ps1 (pure parts only; no CS2/CSDM). Run: powershell -File record.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\record.ps1')
$script:fail = 0; $script:pass = 0
function Check([string]$name, [bool]$cond) { if ($cond) { $script:pass++; Write-Host "PASS $name" } else { $script:fail++; Write-Host "FAIL $name" } }

# dot-sourcing runs nothing
Check 'idle status' ((Get-RecordStatus).state -eq 'idle')

# layer cfg
$all = 'clean', 'hud', 'depth', 'depthNoEnts', 'players', 'viewModel', 'world', 'particlesBlack', 'particlesWhite'
$names = @(); $bad = $false
foreach ($k in $all) {
    $l = New-RecLayerCfg 'p1' $k 'C:/x/pov'
    $txt = $l -join "`n"
    if ($txt -match '#' -or $txt -match '//') { $bad = $true }
    if ($txt -notmatch "mirv_streams edit p1$k settings p1s$k") { $bad = $true }
}
Check 'layer cfgs: no # no //, bind settings' (-not $bad)
Check 'clean uses h264 mp4' (((New-RecLayerCfg 'p1' 'clean' 'C:/x') -join "`n") -match 'libx264.*C:/x/clean\.mp4')
Check 'hud uses prores mov' (((New-RecLayerCfg 'p1' 'hud' 'C:/x') -join "`n") -match 'prores_ks.*C:/x/hud\.mov')
Check 'depthNoEnts has class flags' (((New-RecLayerCfg 'p1' 'depthNoEnts' 'C:/x') -join "`n") -match 'sc_setclassflags SkinnedObject 8')
Check 'expected files' ((Get-RecExpectedFile 'D' 'depth') -like '*depth.mov' -and (Get-RecExpectedFile 'D' 'clean') -like '*clean.mp4')

# safe path
Check 'safe path ok' ($null -eq (Test-RecSafePath 'C:\cs2-recorder\recordings'))
Check 'safe path #' ($null -ne (Test-RecSafePath 'C:\a#b'))
Check 'safe path non-ascii' ($null -ne (Test-RecSafePath ("C:\k" + [char]0xE4 + "y")))

# insecure regex
Check 'insecure yes' (Test-RecInsecureCmdLine '"cs2.exe" -steam -insecure +exec x')
Check 'insecure at end' (Test-RecInsecureCmdLine 'cs2.exe -insecure')
Check 'insecure missing' (-not (Test-RecInsecureCmdLine 'cs2.exe -steam -novid'))
Check 'insecure lookalike' (-not (Test-RecInsecureCmdLine 'cs2.exe -insecurex'))

# JSON writing: BOM-free, # // guard
$tmp = Join-Path $env:TEMP ('rectest_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-RecJson ([ordered]@{ a = 'x'; b = @(1, 2) }) (Join-Path $tmp 't.json')
$b = [IO.File]::ReadAllBytes((Join-Path $tmp 't.json'))
Check 'json no BOM' (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB))
$threw = $false; try { Write-RecJson @{ p = 'C:/a#b' } (Join-Path $tmp 'x.json') } catch { $threw = $true }
Check 'json rejects #' $threw
$threw = $false; try { Write-RecJson @{ p = 'http://x' } (Join-Path $tmp 'y.json') } catch { $threw = $true }
Check 'json rejects //' $threw

# full file generation with 2 clips + camera
$st = @{
    Demo = 'C:\demos\test demo.dem'; OutDir = $tmp; Player = @{ steamid = '76561198000000000'; name = 'Tester' }
    Clips = @(
        @{ start = 1000; end = 1600; kills = @(@{ tick = 1200; round = 3; weapon = 'ak47'; victim = 'A'; headshot = $true }) },
        @{ start = 5000; end = 5600; kills = @(@{ tick = 5200; round = 7; weapon = 'awp'; victim = 'B' }) }
    )
    Width = 1920; Height = 1080; Fps = 60; Layers = @('clean', 'hud', 'depth')
    Camera = @{ enabled = $true; fov = 50; dist = 110; fps = 120; layers = @('clean', 'players') }
}
$clips = ConvertTo-RecClips $st.Clips @()
Check 'clip names unique' (($clips | ForEach-Object { $_.Name } | Select-Object -Unique).Count -eq 2)
Check 'clip name format' ($clips[0].Name -eq 'clip01_r3_1k')
Check 'camstart default' ($clips[0].CamStart -eq 936)
$paths = New-RecRunFiles $st $clips
foreach ($f in 'config_pov.json', 'config_cam.json', 'MANUAL_STEPS.txt') {
    $b = [IO.File]::ReadAllBytes((Join-Path $paths.RunDir $f))
    Check "$f exists, no BOM" ($b.Length -gt 0 -and -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB))
}
$pov = Get-Content (Join-Path $paths.RunDir 'config_pov.json') -Raw
$cam = Get-Content (Join-Path $paths.RunDir 'config_cam.json') -Raw
Check 'config has no # or //' (-not ($pov -match '#' -or $pov -match '//' -or $cam -match '#' -or $cam -match '//'))
$pj = $pov | ConvertFrom-Json; $cj = $cam | ConvertFrom-Json
Check 'pov framerate/size' ($pj.framerate -eq 60 -and $pj.width -eq 1920 -and $pj.recordingSystem -eq 'HLAE')
Check 'cam framerate' ($cj.framerate -eq 120)
# stream names unique across clips and passes (all "mirv_streams add <type> <name>" targets)
$cfgs = @($pj.sequences[0].cfg, $cj.sequences[0].cfg)
$added = @()
foreach ($c in @($pj, $cj)) { foreach ($s in $c.sequences) { foreach ($m in [regex]::Matches($s.cfg, 'mirv_streams add \w+ (\S+)')) { $added += $m.Groups[1].Value } } }
Check 'stream names in per-clip cfg unique within sequence' (($added | Select-Object -Unique).Count -eq $added.Count)
$cfgP = Get-Content (Join-Path $paths.RunDir 'clip02_r7_1k\pov_cfg.txt') -Raw
Check 'clip2 removes clip1 streams' ($cfgP -match 'mirv_streams remove p1clean' -and $cfgP -match 'mirv_streams add normal p2clean')
$camCfg = Get-Content (Join-Path $paths.RunDir 'clip01_r3_1k\cam_cfg.txt') -Raw
Check 'cam cfg campath lines' ($camCfg -match 'mirv_campath load' -and $camCfg -match 'addAtTick 956 mirv_campath edit start' -and $camCfg -match 'spec_mode 4')
Check 'cfg txt files no # //' (-not ($camCfg -match '#' -or $camCfg -match '//' -or $cfgP -match '#' -or $cfgP -match '//'))
Check 'camera first-clip cam stream prefix' ($camCfg -match 'c1clean')

# hint
Check 'hint steam' ((Get-RecHint 'Steam is not running') -match 'Steam')

Remove-Item -Recurse -Force $tmp
Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
