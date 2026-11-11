<#
.SYNOPSIS
  Builds vaidk-camd (the add-on's camera program) for the Vision AI DevKit.

.DESCRIPTION
  Cross-compiles camd.cpp, image.cpp and talkback.cpp for the camera's 32-bit ARM Linux and writes
  device/camera/vaidk-camd.
  - Compiler: Linaro GCC 6.5 (matches the camera's C++ runtime, libstdc++ 6.0.22). Downloaded
    once from Arm's legacy Linaro toolchain archive and checked against its published MD5.
  - Qualcomm qmmf-sdk headers: vendored in third_party/ (BSD-3-Clause, see NOTICE).
  - The camera's own libraries (Qualcomm's qmmf clients and Android's camera metadata), needed
    only to link. They aren't stored in the repository; the script copies them from a camera
    connected over USB (adb).

.PARAMETER CacheDir
  Where the toolchain and the camera's libraries are kept between builds.
#>
[CmdletBinding()]
param(
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'vaidk-build'),
    [string]$Output = (Join-Path $PSScriptRoot '..\device\camera\vaidk-camd')
)
$ErrorActionPreference = 'Stop'

$toolchainName = 'gcc-linaro-6.5.0-2018.12-i686-mingw32_arm-linux-gnueabihf'
$toolchainUrl = "https://developer.arm.com/-/cdn-downloads/permalink/legacy-linaro-gnu-toolchains/6.5-2018.12/$toolchainName.tar.xz"
$toolchainMd5 = '2f34841973cc65d0d4d264f79b5cd34c'

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$toolchain = Join-Path $CacheDir $toolchainName
$gxx = Join-Path $toolchain 'bin\arm-linux-gnueabihf-g++.exe'
if (-not (Test-Path $gxx)) {
    $archive = Join-Path $CacheDir "$toolchainName.tar.xz"
    if (-not (Test-Path $archive)) {
        Write-Host "Downloading the Linaro GCC 6.5 toolchain (320 MB)..."
        & curl.exe -sS -L --retry 3 -o $archive $toolchainUrl
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $toolchainUrl" }
    }
    $md5 = (Get-FileHash -Algorithm MD5 $archive).Hash.ToLowerInvariant()
    if ($md5 -ne $toolchainMd5) {
        Remove-Item $archive
        throw "Toolchain checksum mismatch ($md5); deleted the download. Run the script again."
    }
    Write-Host "Extracting the toolchain..."
    & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $CacheDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $gxx)) { throw "Couldn't extract $archive" }
}

$libDir = Join-Path $CacheDir 'device-libs'
$cameraLibs = @('libqmmf_recorder_client.so', 'libqmmf_player_client.so', 'libcamera_client.so.0', 'libcamera_metadata.so.0')
$missing = @($cameraLibs | Where-Object { -not (Test-Path (Join-Path $libDir $_)) })
if ($missing.Count -gt 0) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        throw "adb not found. Connect the camera over USB and install the Android platform tools, or copy $($missing -join ', ') from the camera's /usr/lib to $libDir."
    }
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    foreach ($lib in $missing) {
        Write-Host "Copying $lib from the camera..."
        & adb pull "/usr/lib/$lib" (Join-Path $libDir $lib) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "adb pull failed; is the camera connected?" }
    }
}

$outDir = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$flags = @(
    '-std=c++14', '-O2', '-Wall', '-Wextra',
    '-D_GLIBCXX_USE_CXX11_ABI=0',                     # the camera's libraries use the pre-C++11 std::string ABI
    '-mcpu=cortex-a7', '-mfpu=neon-vfpv4', '-mfloat-abi=hard', '-pthread',
    "-I$(Join-Path $PSScriptRoot 'third_party\qmmf-sdk\include')",
    "-I$(Join-Path $PSScriptRoot 'android')",
    (Join-Path $PSScriptRoot 'camd.cpp'),
    (Join-Path $PSScriptRoot 'image.cpp'),
    (Join-Path $PSScriptRoot 'talkback.cpp'),
    '-o', $Output,
    "-L$libDir"
)
$flags += $cameraLibs | ForEach-Object { "-l:$_" }
$flags += '-Wl,--allow-shlib-undefined'               # their own dependencies resolve on the camera
Write-Host "Compiling vaidk-camd..."
& $gxx @flags
if ($LASTEXITCODE -ne 0) { throw "Compilation failed" }
& (Join-Path $toolchain 'bin\arm-linux-gnueabihf-strip.exe') $Output
if ($LASTEXITCODE -ne 0) { throw "strip failed" }
Write-Host ("Built {0} ({1:N0} bytes)" -f (Resolve-Path $Output), (Get-Item $Output).Length)
