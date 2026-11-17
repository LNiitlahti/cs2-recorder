# Tests for tool/lib/setup.ps1 (plain PowerShell, no Pester). Run: powershell -File setup.tests.ps1
# No real downloads/installs/system access: every wrapper is redefined below.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\lib\setup.ps1')

$script:Fail = 0; $script:Pass = 0
function Assert-Eq($actual, $expected, [string]$name) {
    if ("$actual" -eq "$expected") { $script:Pass++; Write-Host "  ok   $name" }
    else { $script:Fail++; Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red }
}
function St($checks, $id) { return (@($checks | Where-Object { $_.id -eq $id })[0]).status }

# ---- fake machine
$LA = 'C:\U\AppData\Local'; $PF = 'C:\Program Files'; $UP = 'C:\U'
function New-World { return @{ Files = @{}; Texts = @{}; Services = @(); Cmds = @{}; Reg = @{}; Ext = @{}; Version = $null; Psql = @(); Log = (New-Object Collections.ArrayList) } }
function Get-EnvSafe([string]$Name) {
    switch ($Name) { 'LOCALAPPDATA' { $LA } 'ProgramFiles' { $PF } 'ProgramFiles(x86)' { 'C:\Program Files (x86)' } 'USERPROFILE' { $UP } 'SystemRoot' { 'C:\Windows' } default { $null } }
}
function Test-PathSafe([string]$Path) { return $W.Files.ContainsKey($Path.ToLower()) }
function Read-TextSafe([string]$Path) { return $W.Texts[$Path.ToLower()] }
function Get-ServiceSafe([string]$Pattern) { return @($W.Services) }
function Start-ServiceSafe([string]$Name) { $W.Log.Add("start-service $Name") | Out-Null; return $false }
function Start-ElevatedSafe([string]$Command) { $W.Log.Add("elevate $Command") | Out-Null; foreach ($s in $W.Services) { $s.Status = 'Running' }; return $true }
function Get-CommandSafe([string]$Name) { if ($W.Cmds.ContainsKey($Name)) { return @($W.Cmds[$Name]) } else { return $null } }
function Get-RegValueSafe([string]$Key, [string]$Name) { return $W.Reg[$Key] }
function Find-FilesSafe([string]$Pattern) { return @($W.Psql) }
function Get-FileVersionSafe([string]$Dir) { return $W.Version }
function Invoke-ExternalSafe([string]$Exe, [string[]]$Arguments) {
    $W.Log.Add("run $Exe $($Arguments -join ' ')") | Out-Null
    foreach ($k in $W.Ext.Keys) { if ("$Exe $($Arguments -join ' ')" -like $k) { return $W.Ext[$k] } }
    return @{ Code = -1; Out = '' }
}
function Add-UserPathSafe([string]$Dir) { $W.Log.Add("path+ $Dir") | Out-Null }
function Get-NowStamp { return '20260101000000' }
function Get-JsonSafe([string]$Url) { $W.Log.Add("json $Url") | Out-Null; return $W.Json[$Url] }
function Invoke-Download([string]$Url, [string]$Dest, [scriptblock]$OnBytes) { $W.Log.Add("download $Url") | Out-Null; $W.Files[$Dest.ToLower()] = $true }
function Get-FileHeaderBytes([string]$Path, [int]$Count = 2) { return $W.Header }
function Get-FileSha256([string]$Path) { return $W.Sha }
function Expand-ZipSafe([string]$Zip, [string]$Dest) { $W.Log.Add("expand $Dest") | Out-Null }
function Find-FilesInTree([string]$Root, [string]$Name) { return @([pscustomobject]@{ FullName = "$Root\x\$Name"; DirectoryName = "$Root\x" }) }
function New-DirSafe([string]$Path) { }
function Move-ItemSafe([string]$From, [string]$To) { $W.Log.Add("move $From -> $To") | Out-Null; $W.Files[$To.ToLower()] = $true; $W.Files[(Join-PathSafe $To 'hlae.exe').ToLower()] = $true }
function Rename-ItemSafe([string]$Path, [string]$NewName) { $W.Log.Add("rename $Path -> $NewName") | Out-Null }
function Remove-TempSafe([string]$Path) { $W.Log.Add("remove-temp $Path") | Out-Null; $W.Files.Remove($Path.ToLower()) }

function Add-File($p) { $W.Files[$p.ToLower()] = $true }
function New-Svc($status) { return [pscustomobject]@{ Name = 'postgresql-x64-16'; Status = $status } }

# ---- scenario 1: empty PC
Write-Host 'Scenario: empty PC'
$W = New-World
$c = Get-SetupCheck
Assert-Eq (St $c 'csdm') 'fixable' 'csdm fixable'
Assert-Eq (St $c 'postgres') 'manual' 'postgres manual'
Assert-Eq (St $c 'postgres_path') 'manual' 'postgres_path manual'
Assert-Eq (St $c 'steam') 'manual' 'steam manual'
Assert-Eq (St $c 'cs2') 'manual' 'cs2 manual (no steam)'
Assert-Eq (St $c 'python') 'fixable' 'python fixable'
Assert-Eq (St $c 'venv') 'missing' 'venv missing (no python)'
Assert-Eq (St $c 'hlae') 'fixable' 'hlae fixable'
Assert-Eq (St $c 'ffmpeg') 'fixable' 'ffmpeg fixable'
Assert-Eq $c.Count 9 'nine checks'
Assert-Eq (@($c | Where-Object { $_.status -eq 'manual' -and $_.fixId })).Count 0 'manual has no fixId'

# ---- scenario 2: everything fine
Write-Host 'Scenario: all ok'
$W = New-World
Add-File "$LA\Programs\cs-demo-manager\csdm.cmd"; $W.Version = [version]'3.21.0'
$W.Services = @(New-Svc 'Running'); $W.Cmds['psql.exe'] = [pscustomobject]@{ Source = 'C:\pg\psql.exe' }
$W.Reg['HKCU:\Software\Valve\Steam'] = 'c:/program files (x86)/steam'
Add-File 'c:\program files (x86)\steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe'
$W.Ext['py.exe -3.12 *'] = @{ Code = 0; Out = 'C:\Py312\python.exe' }; Add-File 'C:\Py312\python.exe'
$W.Ext['C:\Py312\python.exe -c*'] = @{ Code = 0; Out = '3.12.10' }
$vp = Get-VenvPy; Add-File $vp; $W.Ext["$vp *"] = @{ Code = 0; Out = '' }
Add-File "$UP\.csdm\hlae\hlae.exe"; Add-File "$UP\.csdm\ffmpeg\bin\ffmpeg.exe"
$c = Get-SetupCheck
foreach ($id in 'csdm', 'postgres', 'postgres_path', 'steam', 'cs2', 'python', 'venv', 'hlae', 'ffmpeg') { Assert-Eq (St $c $id) 'ok' "$id ok" }

# ---- scenario 3: postgres stopped / psql off PATH / old csdm / custom hlae
Write-Host 'Scenario: partial problems'
$W.Services = @(New-Svc 'Stopped'); $W.Version = [version]'3.10.0'; $W.Cmds.Remove('psql.exe')
$W.Psql = @([pscustomobject]@{ FullName = "$PF\PostgreSQL\16\bin\psql.exe"; DirectoryName = "$PF\PostgreSQL\16\bin" })
$W.Texts["$UP\.csdm\settings.json".ToLower()] = '{"video":{"hlae":{"customLocationEnabled":true,"customExecutableLocation":"D:\\nope\\HLAE.exe"}}}'
$c = Get-SetupCheck
Assert-Eq (St $c 'postgres') 'fixable' 'stopped service fixable'
Assert-Eq (St $c 'postgres_path') 'fixable' 'psql missing from PATH but on disk: fixable'
Assert-Eq (St $c 'csdm') 'fixable' 'old csdm fixable'
Assert-Eq (St $c 'hlae') 'manual' 'custom missing hlae manual'
$W.Psql = @()
Assert-Eq (St (Get-SetupCheck) 'postgres_path') 'manual' 'psql nowhere: manual'

# ---- fix: postgres start elevates when plain start fails
Write-Host 'Fix: postgres'
$r = Invoke-SetupFix -Id 'postgres'
Assert-Eq $r.ok $true 'postgres fix ok'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'elevate*' }).Count) 1 'elevated once'
$r = Invoke-SetupFix -Id 'postgres'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'elevate*' }).Count) 1 'idempotent: no second elevation'
$W.Reg = @{}; $W.Cmds = @{}; $W.Files = @{}; $W.Texts = @{}
$r = Invoke-SetupFix -Id 'steam'
Assert-Eq $r.ok $false 'manual item cannot be fixed'

# ---- fix: PATH
Write-Host 'Fix: postgres_path'
$W.Cmds.Remove('psql.exe')
$W.Psql = @([pscustomobject]@{ FullName = "$PF\PostgreSQL\16\bin\psql.exe"; DirectoryName = "$PF\PostgreSQL\16\bin" })
$r = Invoke-SetupFix -Id 'postgres_path'
Assert-Eq (@($W.Log | Where-Object { $_ -eq "path+ $PF\PostgreSQL\16\bin" }).Count) 1 'PATH edited'
Assert-Eq $r.ok $false 'still reported not ok (mock PATH unchanged), no crash'

# ---- fix: hlae download verification
Write-Host 'Fix: hlae download'
$rel = @([pscustomobject]@{ prerelease = $false; tag_name = 'v2.0'; assets = @([pscustomobject]@{ name = 'hlae_2_0_0.zip'; browser_download_url = 'https://example/hlae.zip'; size = 100; digest = 'sha256:' + ('a' * 64) }) })
$W = New-World; $W.Json = @{ 'https://api.github.com/repos/advancedfx/advancedfx/releases' = $rel }
$W.Header = [byte[]](0x3C, 0x68)   # '<h' = web page
$r = Invoke-SetupFix -Id 'hlae'
Assert-Eq $r.ok $false 'non-zip rejected'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'move*' }).Count) 0 'nothing installed after bad header'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'remove-temp*dl_hlae.zip' }).Count -ge 1) $true 'bad download removed'

$W = New-World; $W.Json = @{ 'https://api.github.com/repos/advancedfx/advancedfx/releases' = $rel }
$W.Header = [byte[]](0x50, 0x4B); $W.Sha = ('b' * 64)
$r = Invoke-SetupFix -Id 'hlae'
Assert-Eq $r.ok $false 'sha mismatch rejected'
Assert-Eq ($r.message -match 'SHA256') $true 'message names SHA256'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'move*' }).Count) 0 'nothing installed after bad hash'

$W = New-World; $W.Json = @{ 'https://api.github.com/repos/advancedfx/advancedfx/releases' = $rel }
$W.Header = [byte[]](0x50, 0x4B); $W.Sha = ('a' * 64)
$r = Invoke-SetupFix -Id 'hlae'
Assert-Eq $r.ok $true "good zip + hash installs ($($r.message))"
Assert-Eq (@($W.Log | Where-Object { $_ -like "move*$UP\.csdm\hlae" }).Count) 1 'moved into .csdm\hlae'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'rename*' }).Count) 0 'no rename when nothing existed'
$n = @($W.Log | Where-Object { $_ -like 'download*' }).Count
$r = Invoke-SetupFix -Id 'hlae'
Assert-Eq (@($W.Log | Where-Object { $_ -like 'download*' }).Count) $n 'idempotent: already ok, no re-download'

# ---- SetupAll: python then venv unlock in order (winget path mocked)
Write-Host 'SetupAll'
$W = New-World
$W.Cmds['winget.exe'] = [pscustomobject]@{ Source = 'C:\winget.exe' }
$W.Ext['winget.exe *'] = @{ Code = 0; Out = '' }
# simulate: after winget runs, python appears; after venv command, helper becomes ready
$script:RunOrig = ${function:Invoke-ExternalSafe}
function Invoke-ExternalSafe([string]$Exe, [string[]]$Arguments) {
    $W.Log.Add("run $Exe $($Arguments -join ' ')") | Out-Null
    if ($Exe -eq 'winget.exe') { Add-File 'C:\Py312\python.exe'; $W.Ext['py.exe -3.12 *'] = @{ Code = 0; Out = 'C:\Py312\python.exe' }; $W.Ext['C:\Py312\python.exe -c*'] = @{ Code = 0; Out = '3.12.1' }; return @{ Code = 0; Out = '' } }
    if ($Arguments -contains 'venv') { Add-File (Get-VenvPy); return @{ Code = 0; Out = '' } }
    if ($Arguments -contains 'pip') { $W.Ext["$(Get-VenvPy) *"] = @{ Code = 0; Out = '' }; return @{ Code = 0; Out = '' } }
    foreach ($k in $W.Ext.Keys) { if ("$Exe $($Arguments -join ' ')" -like $k) { return $W.Ext[$k] } }
    return @{ Code = -1; Out = '' }
}
$prog = New-Object Collections.ArrayList
$final = Invoke-SetupAll -OnProgress { param($p, $m) $prog.Add($p) | Out-Null }
Assert-Eq (St $final 'python') 'ok' 'python fixed'
Assert-Eq (St $final 'venv') 'ok' 'venv fixed after python (dependency order)'
Assert-Eq (St $final 'steam') 'manual' 'manual items stay manual'
Assert-Eq ($prog.Count -gt 0 -and $prog[-1] -eq 100) $true 'progress reported, ends at 100'

# ---- parse + dot-source side effects
Write-Host 'Misc'
$errs = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\lib\setup.ps1'), [ref]$null, [ref]$errs)
Assert-Eq @($errs).Count 0 'setup.ps1 parses clean'

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
