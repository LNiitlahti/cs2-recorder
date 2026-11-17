# Tests for Set-GraphicsFix on a TEMP copy of a real-format cs2_video.txt (never touches Steam files).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\preflight.ps1')
$script:fail = 0
function Assert([string]$n, [bool]$c) { if ($c) { Write-Host "PASS $n" } else { Write-Host "FAIL $n"; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('gfx_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$cfg = Join-Path $tmp 'cs2_video.txt'
$orig = "`"video.cfg`"`r`n{`r`n`t`"setting.fullscreen`"`t`t`"0`"`r`n`t`"setting.mat_vsync`"`t`t`"1`"`r`n`t`"Version`"`t`t`"17`"`r`n`t`"setting.videocfg_fsr_detail`"`t`t`"2`"`r`n`t`"setting.msaa_samples`"`t`t`"4`"`r`n}`r`n"
function Reset-Cfg { [IO.File]::WriteAllText($cfg, $orig, (New-Object Text.UTF8Encoding($false))) }
Get-ChildItem $tmp -Filter '*.bak_*' | Remove-Item -ErrorAction SilentlyContinue

function Get-VideoCfgPathPf([string]$steam, [string]$id64) { return $cfg }
$script:running = $false
function Test-Cs2Running { return $script:running }
$tbl = Join-Path $tmp 'graphics_max.json'
'{"verified":false,"settings":[{"key":"setting.mat_vsync","equals":"0"},{"key":"setting.videocfg_fsr_detail","equals":"0"},{"key":"setting.not_in_file","equals":"9"}]}' | Set-Content -Path $tbl -Encoding UTF8
function Get-GraphicsTablePath { return $tbl }

# 1 fixes only what differs, keeps everything else byte-identical
Reset-Cfg
$r = Set-GraphicsFix -SteamPath 'C:\S' -AccountId '76561198000000000'
$now = [IO.File]::ReadAllText($cfg); $c = ConvertFrom-VideoCfg $now
Assert 'fix ok' ($r.ok -eq $true)
Assert 'vsync now 0' ($c['setting.mat_vsync'] -eq '0')
Assert 'fsr now 0' ($c['setting.videocfg_fsr_detail'] -eq '0')
Assert 'msaa untouched' ($c['setting.msaa_samples'] -eq '4')
Assert 'key missing from file not added' (-not $c.ContainsKey('setting.not_in_file'))
Assert 'only the two values changed' (($now -replace '"0"', '"X"' -replace '"1"', '"X"' -replace '"2"', '"X"') -eq ($orig -replace '"0"', '"X"' -replace '"1"', '"X"' -replace '"2"', '"X"'))
Assert 'backup kept with original content' ($r.backup -and (Test-Path $r.backup) -and ([IO.File]::ReadAllText($r.backup) -eq $orig))
Assert 'no BOM written' (([IO.File]::ReadAllBytes($cfg)[0]) -eq 0x22)

# 2 second run: nothing to change, no new backup
$n1 = @(Get-ChildItem $tmp -Filter '*.bak_*').Count
$r = Set-GraphicsFix -SteamPath 'C:\S' -AccountId '76561198000000000'
Assert 'idempotent' ($r.ok -and $r.changed.Count -eq 0 -and @(Get-ChildItem $tmp -Filter '*.bak_*').Count -eq $n1)

# 3 refuses while CS2 runs, file untouched
Reset-Cfg; $script:running = $true
$r = Set-GraphicsFix -SteamPath 'C:\S' -AccountId '76561198000000000'
Assert 'refuses while CS2 runs' ((-not $r.ok) -and ([IO.File]::ReadAllText($cfg) -eq $orig))
$script:running = $false

# 4 verification failure restores the original
Reset-Cfg
function Write-PreflightText([string]$path, [string]$text) { }   # simulate a write that does not stick
$r = Set-GraphicsFix -SteamPath 'C:\S' -AccountId '76561198000000000'
Assert 'failed verify reports failure' (-not $r.ok)
Assert 'original intact after failed verify' ([IO.File]::ReadAllText($cfg) -eq $orig)

# 5 missing file -> clear message, no throw
Remove-Item $cfg -Force
$r = Set-GraphicsFix -SteamPath 'C:\S' -AccountId '76561198000000000'
Assert 'missing file handled' ((-not $r.ok) -and $r.message)

# 6 the check offers the fix
Reset-Cfg
function Write-PreflightText([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text) }
$g = Test-GraphicsCheck 'C:\S' '76561198000000000'
Assert 'mismatch check carries fixId' ($g.status -eq 'warn' -and $g.fixId -eq 'graphics')

Remove-Item $tmp -Recurse -Force
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host 'ALL PASSED'; exit 0
