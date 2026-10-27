# Build the full iPASide Windows installer:
#   1. assemble the portable Python engine
#   2. build the Flutter Windows runner (AOT release)
#   3. compile the Inno Setup installer
#
# Usage (from repo root):  pwsh packaging/build-installer.ps1 -Version 1.0.0

param(
    [string]$Version = "1.2.13",
    [string]$Python = "",
    [string]$Flutter = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# 1. Portable Python engine
#
# Rebuilt whenever any engine source is newer than the assembled copy. This used
# to be "build it if it is not there", which meant every engine change after the
# first build was silently left out: the installer packaged the previous engine and
# the only symptom was the shipped app missing a command it was built to have.
# Caught exactly that way, on a release that had already been signed off.
$engineStamp = "dist/engine/python/python.exe"
$engineSource = "src/iPASide.Engine"
$rebuildEngine = $true
if (Test-Path $engineStamp) {
    $built = (Get-Item $engineStamp).LastWriteTimeUtc
    $newestSource = Get-ChildItem $engineSource -Recurse -File -Include *.py, *.txt, *.pem, *.exe |
        Where-Object { $_.FullName -notmatch '\\__pycache__\\' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $rebuildEngine = $newestSource -and $newestSource.LastWriteTimeUtc -gt $built
    if ($rebuildEngine) {
        Write-Host "== Engine is stale ($($newestSource.Name) is newer); rebuilding =="
    }
}
if ($rebuildEngine) {
    Write-Host "== Building portable engine =="
    & "$PSScriptRoot/build-engine.ps1" -Python $Python
    if ($LASTEXITCODE -ne 0) { throw "build-engine.ps1 failed ($LASTEXITCODE)" }
}

# 2. App (Flutter AOT release; no runtime prerequisite for end users)
Write-Host "== Building app =="
$flutterExe = $Flutter
if (-not $flutterExe) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) {
        $flutterExe = $cmd.Source
    }
    elseif (Test-Path "C:\src\flutter\bin\flutter.bat") {
        $flutterExe = "C:\src\flutter\bin\flutter.bat"
    }
    else {
        throw "Flutter SDK not found. Install it, or pass -Flutter <path to flutter.bat>."
    }
}

Push-Location src/iPASide.Flutter
try {
    # Always from clean. `flutter build` leaves the output of a plugin you have
    # since removed exactly where it was, so an incremental tree accumulates files
    # that no longer belong in a release. The allow-list below catches them and
    # stops the build, which is the right outcome but a poor way to find out: the
    # first sign is a failed release. A release build is not the inner loop, so
    # spending ~20s to make the tree match the manifest is the better trade.
    & $flutterExe clean
    if ($LASTEXITCODE -ne 0) { throw "flutter clean failed ($LASTEXITCODE)" }

    & $flutterExe build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$runnerDir = "src/iPASide.Flutter/build/windows/x64/runner/Release"
if (-not (Test-Path "$runnerDir/iPASide.exe")) {
    throw "expected $runnerDir/iPASide.exe - check BINARY_NAME in windows/CMakeLists.txt"
}

# The runner needs the exe, flutter_windows.dll, one DLL per plugin, and data/
# (the AOT snapshot, ICU data and bundled assets). Copy exactly that, derived
# from the plugins CMake actually links, rather than copying the build directory
# wholesale: `flutter build` does not delete the output of a plugin you have
# since removed, so a tree that is not freshly cleaned still holds its DLL and
# an unguarded copy ships it. That is how a dead file_selector plugin reached a
# release. Anything here we cannot account for stops the build instead of
# silently becoming part of the payload.
$pluginsCmake = "src/iPASide.Flutter/windows/flutter/generated_plugins.cmake"
$cmakeText = Get-Content $pluginsCmake -Raw
$declaredPlugins = foreach ($listName in "FLUTTER_PLUGIN_LIST", "FLUTTER_FFI_PLUGIN_LIST") {
    $match = [regex]::Match($cmakeText, "APPEND\s+$listName(?<body>[^)]*)\)")
    if (-not $match.Success) { throw "could not read $listName from $pluginsCmake" }
    $match.Groups["body"].Value -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
Write-Host "  plugins: $($declaredPlugins -join ', ')"

$expected = @("iPASide.exe", "flutter_windows.dll", "data")
$expected += $declaredPlugins | ForEach-Object { "${_}_plugin.dll" }

$stale = @()
foreach ($entry in Get-ChildItem $runnerDir) {
    if ($expected -contains $entry.Name) { continue }
    # A *_plugin.dll with no matching entry in generated_plugins.cmake is
    # provably orphaned: nothing links it. Anything else might be a plugin's
    # bundled native library, which we must not drop on a guess.
    if ($entry.Name -like "*_plugin.dll") { $stale += $entry.Name; continue }
    throw @"
unexpected file in $runnerDir : $($entry.Name)
It is not the runner, flutter_windows.dll, data/, or a DLL for a declared
plugin ($($declaredPlugins -join ', ')). If the build now needs it, add it to
the `$expected list in this script; if it is left over from a removed
dependency, run 'flutter clean' in src/iPASide.Flutter. Refusing to guess.
"@
}
if ($stale) {
    Write-Warning "ignoring orphaned plugin DLL(s) from a removed dependency: $($stale -join ', ')"
    Write-Warning "run 'flutter clean' in src/iPASide.Flutter to clear them"
}

Remove-Item "publish/app" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "publish/app" | Out-Null
foreach ($name in $expected) {
    $source = Join-Path $runnerDir $name
    if (-not (Test-Path $source)) { throw "missing from the Flutter build output: $name" }
    Copy-Item $source "publish/app" -Recurse -Force
}
Write-Host "  payload: $((Get-ChildItem 'publish/app' -Recurse -File).Count) files"

# 3. Installer
Write-Host "== Compiling installer =="
$iscc = $null
$candidates = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
foreach ($c in $candidates) { if (Test-Path $c) { $iscc = $c; break } }
if (-not $iscc) {
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source } else { throw "Inno Setup (ISCC.exe) not found. Install JRSoftware.InnoSetup." }
}
& $iscc "/DAppVersion=$Version" "packaging/iPASide.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

# 4. Checksums. The in-app updater refuses to install anything it cannot verify
# against a published SHA256SUMS.txt, so this file is part of every release, not
# an optional extra. Format matches sha256sum: "<hex>  <filename>".
Write-Host "== Writing SHA256SUMS.txt =="
$installerDir = "dist/installer"
$sumsPath = Join-Path $installerDir "SHA256SUMS.txt"
$lines = foreach ($file in Get-ChildItem $installerDir -Filter *.exe | Sort-Object Name) {
    "{0}  {1}" -f (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $file.Name
}
Set-Content -Path $sumsPath -Value $lines -Encoding ascii
$lines | ForEach-Object { Write-Host "  $_" }

Write-Host "Installer -> dist/installer/iPASide-Setup-$Version-x64.exe"
Write-Host "Checksums -> $sumsPath"
