# Tests for tool\app.ps1: starts it with -NoWindow on a test port, calls endpoints, stops it.
$ErrorActionPreference = 'Stop'
$tests = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path (Split-Path -Parent $tests) 'app.ps1'
$port = 47000 + (Get-Random -Maximum 900)
$base = "http://127.0.0.1:$port"
$script:fail = 0
function Check([string]$name, [bool]$cond) { if ($cond) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ } }
function Req([string]$method, [string]$path, [string]$token = '', $body = $null) {
    $h = @{}; if ($token) { $h['X-Token'] = $token }
    try {
        $p = @{ Uri = ($base + $path); Method = $method; Headers = $h; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
        $r = Invoke-WebRequest @p
        return @{ code = [int]$r.StatusCode; body = $r.Content }
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        return @{ code = $code; body = '' }
    }
}
$out = Join-Path $env:TEMP "cs2app_test_$port.out"
$proc = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$app`"", '-NoWindow', '-Port', $port) -RedirectStandardOutput $out -WindowStyle Hidden -PassThru
try {
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if ((Get-Content $out -ErrorAction SilentlyContinue) -match 'TOKEN=') { $ok = $true; break } }
    Check 'server starts' $ok
    if (-not $ok) { throw 'server did not start' }
    $tok = ((Get-Content $out) | Where-Object { $_ -match '^TOKEN=' } | Select-Object -First 1).Substring(6).Trim()

    $r = Req GET '/'
    Check 'index served' ($r.code -eq 200 -and $r.body -match 'CS2 RECORDER')
    Check 'token injected into index' ($r.body.Contains($tok))
    Check 'css served' ((Req GET '/app.css').code -eq 200)
    Check 'js served' ((Req GET '/app.js').code -eq 200)
    Check 'missing file 404' ((Req GET '/nope.txt').code -eq 404)
    Check 'traversal (..) blocked' ((Req GET '/..%2fapp.ps1').code -ne 200)
    Check 'traversal (..\) blocked' ((Req GET '/..%5capp.ps1').code -ne 200)
    Check 'traversal (%2e%2e) blocked' ((Req GET '/%2e%2e/app.ps1').code -ne 200)
    # raw socket request with literal ../ (Invoke-WebRequest normalises it away)
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port); $s = $c.GetStream()
    $bytes = [Text.Encoding]::ASCII.GetBytes("GET /../app.ps1 HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nConnection: close`r`n`r`n"); $s.Write($bytes, 0, $bytes.Length)
    $sr = New-Object IO.StreamReader($s); $resp = $sr.ReadToEnd(); $c.Close()
    Check 'raw ../ does not leak source' (-not ($resp -match 'HttpListener'))
    Check 'api without token is 403' ((Req GET '/api/check').code -eq 403)
    Check 'api bad token is 403' ((Req GET '/api/check' 'wrong').code -eq 403)
    Check 'ping with token' ((Req GET '/api/ping' $tok).code -eq 200)
    $r = Req GET '/api/check' $tok
    $j = $null; try { $j = $r.body | ConvertFrom-Json } catch {}
    Check '/api/check returns JSON' ($r.code -eq 200 -and $null -ne $j -and $null -ne $j.ok)
    $r = Req POST '/api/estimate' $tok @{ ticks = @(); layers = @('clean'); outDir = 'C:\rec'; width = 1920; height = 1080; fps = 60 }
    $j = $r.body | ConvertFrom-Json
    Check '/api/estimate works' ($r.code -eq 200 -and $j.ok -eq $true)
    $r = Req POST '/api/demo' $tok @{ path = 'C:\does\not\exist.dem' }
    $j = $r.body | ConvertFrom-Json
    Check '/api/demo missing file gives plain error' ($j.ok -eq $false -and $j.error)
    $r = Req GET '/api/report?format=text' $tok
    Check '/api/report text' ($r.code -eq 200)
    $r = Req GET '/api/nothing' $tok
    Check 'unknown api is 404' ($r.code -eq 404)
    [void](Req POST '/api/quit' $tok @{})
    Start-Sleep -Seconds 2
    Check 'server stops on quit' ($proc.HasExited)
} catch { Write-Host "ERROR $_"; $script:fail++ }
finally {
    if (-not $proc.HasExited) { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null }
    Remove-Item $out -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Host "$script:fail test(s) FAILED"; exit 1 }
Write-Host 'All tests passed'; exit 0
