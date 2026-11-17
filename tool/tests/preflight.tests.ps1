$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\preflight.ps1')
$script:fail = 0
function Assert($name, $cond) { if ($cond) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:fail++ } }
function St($r, $id) { ($r.checks | Where-Object { $_.id -eq $id }).status }

$id = '76561198000000000'
$good = 'C:\rec'
$script:cs2 = $false; $script:gb = 100; $script:age = 1; $script:files = @{}
function Test-Cs2Running { return $script:cs2 }
function Get-FreeSpaceGB([string]$p) { return $script:gb }
function Get-GraphicsTableAgeDays([string]$p) { return $script:age }
function Read-PreflightText([string]$p) { if ($p -like '*cs2_video.txt') { return $script:files['cfg'] } else { return [System.IO.File]::ReadAllText($p) } }
$script:files['cfg'] = '"video.cfg" { "setting.mat_vsync" "0" "setting.unknown_x" "9" }'

$r = Get-Preflight -AccountId $id -AccountKind separate -DemoInfo $null -OutDir $good -SteamPath 'C:\S'
Assert 'happy path not blocking' (-not $r.blocking)
Assert 'six checks' ($r.checks.Count -eq 6)
Assert 'graphics ok' ((St $r 'graphics') -eq 'ok')

$r = Get-Preflight -AccountId $id -AccountKind main -OutDir $good -SteamPath 'C:\S'
Assert 'main blocks' ($r.blocking -and (St $r 'account') -eq 'block')

$script:cs2 = $true
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'cs2 running blocks' ((St $r 'cs2_closed') -eq 'block' -and $r.blocking)
$script:cs2 = $false

$demo = [pscustomobject]@{ header = [pscustomobject]@{ network_protocol = '14192' } }
$r = Get-Preflight -AccountId $id -DemoInfo $demo -OutDir $good -SteamPath 'C:\S'
Assert 'patch 14192 blocks' ((St $r 'demo_patch') -eq 'block')
$demo2 = [pscustomobject]@{ header = [pscustomobject]@{ network_protocol = '141920' } }
$r = Get-Preflight -AccountId $id -DemoInfo $demo2 -OutDir $good -SteamPath 'C:\S'
Assert 'other patch ok' ((St $r 'demo_patch') -eq 'ok')

$script:gb = 5
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'low disk warns, not block' ((St $r 'disk_space') -eq 'warn' -and -not $r.blocking)
$script:gb = 100

foreach ($bad in 'C:\rec#1', 'C:\r%c', 'C:\r"c', "C:\r'c", 'C:\r&c', 'C:\r^c', ("C:\r" + [char]0xE4 + "c")) {
    $r = Get-Preflight -AccountId $id -OutDir $bad -SteamPath 'C:\S'
    Assert "unsafe path blocks: $bad" ((St $r 'output_path') -eq 'block')
}

$script:files['cfg'] = '"video.cfg" { "setting.mat_vsync" "1" }'
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'mismatch warns only' ((St $r 'graphics') -eq 'warn' -and -not $r.blocking)

$script:files['cfg'] = '"video.cfg" { "setting.other" "1" }'
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'missing known key = no opinion' ((St $r 'graphics') -eq 'ok')

$script:files['cfg'] = $null
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'missing cfg warns' ((St $r 'graphics') -eq 'warn' -and -not $r.blocking)

$script:files['cfg'] = '"x" { "setting.mat_vsync" "0" }'; $script:age = 40
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'stale table warns' ((St $r 'graphics') -eq 'warn')
$script:age = 1

function Get-GraphicsTablePath { 'C:\nonexistent\graphics_max.json' }
function Read-PreflightText([string]$p) { if ($p -like '*cs2_video.txt') { return '"a" { }' } else { return $null } }
$r = Get-Preflight -AccountId $id -OutDir $good -SteamPath 'C:\S'
Assert 'missing table warns' ((St $r 'graphics') -eq 'warn' -and -not $r.blocking)

if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host 'ALL PASSED'; exit 0
