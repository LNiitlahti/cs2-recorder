# CS2 Recorder installer: copies the tool to C:\cs2-recorder and creates Desktop + Start menu icons.
# Started by INSTALL.bat. Keeps the 'data' folder (settings, demo reader) and 'recordings' on updates.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$src = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$target = 'C:\cs2-recorder'
$version = '?'
try { $version = (Get-Content (Join-Path $src 'VERSION.txt') -Raw).Trim() } catch {}

function Say([string]$m, [string]$icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($m, 'CS2 Recorder setup', 'OK', $icon)
}

try {
    # 1. copy files (skip when INSTALL.bat is run from the installed folder itself)
    if ((Resolve-Path $src).Path.TrimEnd('\') -ne $target) {
        try { New-Item -ItemType Directory -Force -Path (Join-Path $target 'tool') | Out-Null }
        catch {
            $target = Join-Path $env:LOCALAPPDATA 'cs2-recorder'   # fallback if C:\ is locked down
            New-Item -ItemType Directory -Force -Path (Join-Path $target 'tool') | Out-Null
        }
        foreach ($f in 'START.bat', 'INSTALL.bat', 'README.txt', 'VERSION.txt') {
            if (Test-Path (Join-Path $src $f)) { Copy-Item -Force (Join-Path $src $f) $target }
        }
        Copy-Item -Force -Recurse (Join-Path $src 'tool\*') (Join-Path $target 'tool')
    }
    Get-ChildItem $target -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

    # 2. shortcuts (the black console window starts minimised)
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
    foreach ($dir in $places) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $lnk = $shell.CreateShortcut((Join-Path $dir 'CS2 Recorder.lnk'))
        $lnk.TargetPath = Join-Path $target 'START.bat'
        $lnk.WorkingDirectory = $target
        $lnk.IconLocation = (Join-Path $target 'tool\icon.ico') + ',0'
        $lnk.Description = 'Record CS2 frags from demos'
        $lnk.WindowStyle = 7
        $lnk.Save()
    }

    Say ("CS2 Recorder $version is installed in:`r`n$target`r`n`r`n" +
         "From now on, start it with the 'CS2 Recorder' icon on your Desktop (also in the Start menu).`r`n`r`n" +
         "You can delete the downloaded zip and the extracted folder.`r`n`r`nThe recorder opens now.")
    Start-Process -FilePath (Join-Path $target 'START.bat') -WorkingDirectory $target -WindowStyle Minimized
}
catch {
    Say ("Installation failed:`r`n`r`n" + $_.Exception.Message + "`r`n`r`nYou can still use the tool by running START.bat from the extracted folder.") 'Warning'
    exit 1
}
