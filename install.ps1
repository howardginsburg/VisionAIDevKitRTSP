<#
.SYNOPSIS
    Installs the Vision AI DevKit RTSP add-on on a camera connected over USB.

.DESCRIPTION
    Copies the add-on to the camera with ADB, installs it and restarts the camera. After a new
    install the camera opens its setup Wi-Fi network: join it from a phone or computer and finish
    setup in the browser. SSH is not needed.

.PARAMETER KeepSettings
    Reinstall the add-on (for example after changing it) and keep the camera's Wi-Fi network,
    admin account and settings.

.PARAMETER Uninstall
    Remove the add-on. The camera goes back to its original software and setup.

.PARAMETER Serial
    ADB serial number of the camera when more than one ADB device is connected (see: adb devices).

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -KeepSettings
#>
[CmdletBinding()]
param(
    [switch]$KeepSettings,
    [switch]$Uninstall,
    [string]$Serial
)

$ErrorActionPreference = 'Stop'

function Find-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @((Join-Path $PSScriptRoot 'platform-tools\adb.exe'))
    if ($env:ANDROID_HOME) { $candidates += Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    return $null
}

$adb = Find-Adb
if (-not $adb) {
    throw 'adb was not found. Install Android SDK Platform-Tools (https://developer.android.com/tools/releases/platform-tools) and add it to PATH, or extract it next to this script.'
}
$target = @()
if ($Serial) { $target = @('-s', $Serial) }

function Invoke-Adb {
    # adb reports progress on stderr; don't let Windows PowerShell treat that as an error.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $adb @target @args 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "adb $($args -join ' ') failed: $($output -join ' ')" }
    return $output
}

function Get-CameraInfo {
    $info = @{}
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $adb @target shell sh /opt/vaidk/web/ui.sh info 2>$null) }
    finally { $ErrorActionPreference = $previous }
    foreach ($line in $lines) {
        if ("$line" -match '^([a-z_]+)=(.*)$') { $info[$Matches[1]] = $Matches[2].Trim() }
    }
    return $info
}

function Wait-Camera([scriptblock]$Ready, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $info = Get-CameraInfo
        if (& $Ready $info) { return $info }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $null
}

Invoke-Adb start-server | Out-Null
if (-not $Serial) {
    $devices = @(Invoke-Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' })
    if ($devices.Count -eq 0) {
        throw 'No camera found. Connect it with a USB-C cable, make sure it is on, then check that "adb devices" lists it.'
    }
    if ($devices.Count -gt 1) { throw 'More than one ADB device is connected. Choose the camera with -Serial (see: adb devices).' }
}

$check = (Invoke-Adb shell 'cat /etc/version; test -f /vendor/etc/camera/InitCamx && echo vision-ai-devkit') -join "`n"
if ($check -notmatch 'vision-ai-devkit') { throw 'The connected device does not look like a Vision AI DevKit.' }
Write-Host "Camera firmware: $(($check -split "`n")[0].Trim())"

# Copy the add-on with Unix line endings (a git checkout on Windows may have converted them).
$staging = Join-Path ([IO.Path]::GetTempPath()) ('vaidk-' + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'device') -Destination $staging -Recurse
try {
    foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }   # binary (camera/vaidk-camd)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($text.Contains("`r")) { [IO.File]::WriteAllText($file.FullName, $text.Replace("`r`n", "`n")) }
    }
    Invoke-Adb shell 'rm -rf /tmp/vaidk-install' | Out-Null
    Write-Host 'Copying the add-on to the camera...'
    Invoke-Adb push $staging /tmp/vaidk-install | Out-Null
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}

$action = 'install'
if ($Uninstall) { $action = 'uninstall' } elseif ($KeepSettings) { $action = 'install --keep-settings' }
$result = Invoke-Adb shell "sh /tmp/vaidk-install/install-device.sh $action 2>&1; rm -rf /tmp/vaidk-install"
$result | Where-Object { $_ -and $_ -ne 'VAIDK-OK' } | ForEach-Object { Write-Host "  $_" }
if (-not ($result -contains 'VAIDK-OK')) { throw 'The camera reported an error (see above). Nothing was restarted.' }

Write-Host 'Restarting the camera (about 2 minutes)...'
Invoke-Adb reboot | Out-Null
Start-Sleep -Seconds 10
Invoke-Adb wait-for-device | Out-Null

if ($Uninstall) {
    Write-Host 'Done. The camera runs its original software again and opens its original setup network.'
    return
}

$info = Wait-Camera { param($i) $i['state'] -and $i['state'] -ne 'starting' } 240
if (-not $info) {
    Write-Warning 'The camera is taking longer than expected to start. Watch its lights, then run: adb shell sh /opt/vaidk/web/ui.sh info'
    return
}

if ($info['state'] -eq 'setup') {
    $info = Wait-Camera { param($i) $i['setup_ap'] -eq 'on' -and $i['setup_ssid'] -like 'MSIoT*' } 60
    $ssid = if ($info) { $info['setup_ssid'] } else { 'MSIoT_...' }
    Write-Host ''
    Write-Host 'Done. Finish setup from a phone or computer:' -ForegroundColor Green
    Write-Host "  1. Join the Wi-Fi network '$ssid'. Its password is on the sticker under the camera"
    Write-Host '     (or run: adb shell cat /persist/data/wifi.bin).'
    Write-Host '  2. A sign-in page should open. If it does not, browse to http://192.168.143.1/'
    Write-Host '  3. Choose your Wi-Fi network, create the admin account (it''s also your SSH login), and select Save and connect.'
    return
}

$info = Wait-Camera { param($i) $i['ip'] -and $i['streaming'] -eq 'yes' } 120
if (-not $info) { $info = Get-CameraInfo }
$ip = if ($info['ip']) { $info['ip'] } else { '<camera-ip>' }
Write-Host ''
Write-Host 'Done. The camera kept its settings.' -ForegroundColor Green
Write-Host "  Setup page:  http://$ip/"
Write-Host "  Main stream: rtsp://${ip}:8900/live$(if ($info['audio'] -eq 'on') { ' (with microphone audio; turn it off on the setup page)' })"
Write-Host "  Sub stream:  rtsp://${ip}:8901/live"
if (-not $info['admin']) {
    Write-Host '  No admin account is set yet: hold the power button for 5 seconds and finish setup on the camera''s Wi-Fi,'
    Write-Host '  or run: adb shell sh /opt/vaidk/web/ui.sh set-admin admin   (then type the password and press Enter)'
}
