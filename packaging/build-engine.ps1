# Build a self-contained, portable Python engine that ships with the installer.
#
# Rather than freeze with PyInstaller (which mis-handles unicorn's native library
# that anisette drives to emulate Apple's provisioning code), we assemble a
# standalone CPython: the trimmed standard library + the engine's runtime deps
# installed fresh into a private site-packages + the ipaside_engine package. This
# runs the real, unmodified wheels exactly as they do in development.
#
# Output: dist/engine/python/python.exe  (run as `python.exe -m ipaside_engine`)
#
# Usage (from repo root):  pwsh packaging/build-engine.ps1

param([string]$Python = "")

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not $Python) {
    if (Test-Path ".\.venv\Scripts\python.exe") { $Python = ".\.venv\Scripts\python.exe" } else { $Python = "python" }
}

# The relocatable standard CPython install to copy the stdlib from.
$base = (& $Python -c "import sys; print(sys.base_prefix)").Trim()
if (-not (Test-Path (Join-Path $base "python.exe"))) {
    throw "No standard python.exe under base_prefix '$base' (a Store/embeddable Python won't copy cleanly)."
}

$dest = "dist\engine"
$eng = "$dest\python"
$site = "$eng\Lib\site-packages"
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $eng | Out-Null

Write-Host "== Copying trimmed standard library from $base =="
# The interpreter root is copied by ALLOW-LIST, not wholesale. Copying everything shipped
# two real payloads: GitHub's actions/setup-python leaves the ~26 MB python-<ver>-amd64.exe
# installer sitting in the interpreter root, and because that is an already-compressed MSI
# bundle LZMA2 cannot squeeze it - it accounted for the entire 68 MB local vs 93 MB CI
# installer gap on its own. A developer's base prefix collects its own litter too (a stray
# libusb-1.0.dll, include\greenlet\greenlet.h, a fonttools man page), which meant local and
# CI builds did not ship the same bytes. An allow-list also fails in the safe direction: a
# missing runtime piece stops the smoke test at the bottom of this script, whereas a
# deny-list silently ships whatever it has not been taught about yet.
#
# python3.dll is the stable-ABI forwarder some wheels link against; vcruntime140*.dll are
# the CRT CPython itself needs. pythonw.exe and python3.exe are deliberately absent: the
# app's engine locator only ever launches engine\python\python.exe.
$rootFiles = @("python.exe", "python*.dll", "vcruntime*.dll", "LICENSE.txt")
foreach ($pattern in $rootFiles) {
    $found = @(Get-ChildItem (Join-Path $base $pattern) -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { throw "base prefix '$base' has no file matching '$pattern'" }
    $found | Copy-Item -Destination $eng
}

# robocopy returns 0-7 on success; swallow its exit code.
# Excluded because nothing in the shipped engine can reach them: site-packages (pip
# installs a fresh one below), tkinter/tcl/idlelib/turtledemo (no GUI here), CPython's own
# test suites, Doc, Scripts (console-script launchers), lib2to3 (the dead 2->3 converter,
# with no importer left in the tree), pydoc_data (help()'s topic text) and ensurepip
# (which bundles a 2 MB pip wheel to bootstrap a pip we never run). .pyc are skipped
# because the compileall pass below regenerates them for this exact interpreter.
robocopy "$base\Lib" "$eng\Lib" /E /NFL /NDL /NJH /NJS /NP `
    /XD site-packages __pycache__ tkinter tcl idlelib turtledemo test tests Doc Scripts lib2to3 pydoc_data ensurepip `
    /XF "*.pyc" | Out-Null
$global:LASTEXITCODE = 0

# The extension modules. _tkinter.pyd plus Tcl/Tk's two ~1.6 MB DLLs cannot work at all
# once Lib\tkinter and tcl\ are gone, and _test*/xxlimited are CPython's C-API test
# extensions, imported only by the test suite that is already excluded.
robocopy "$base\DLLs" "$eng\DLLs" /E /NFL /NDL /NJH /NJS /NP `
    /XF "_tkinter.pyd" "tcl*.dll" "tk*.dll" "_test*.pyd" "_ctypes_test.pyd" "xxlimited*.pyd" | Out-Null
$global:LASTEXITCODE = 0

Write-Host "== Installing runtime dependencies =="
# The target is a fresh portable tree. Ignore host packages and their conflicts:
# pip otherwise warns about unrelated packages in the build venv (for example
# pyOpenSSL, which is not shipped) even though every target dependency is isolated.
& $Python -m pip install --disable-pip-version-check --no-warn-script-location `
    --no-warn-conflicts `
    --ignore-installed `
    --target "$site" -r "src\iPASide.Engine\requirements.txt"
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

Write-Host "== Copying engine package =="
# zsign.exe is git-ignored, so a fresh checkout has none. Without it the app installs
# and starts fine but every sideload fails with "zsign not found".
if (-not (Test-Path "src\iPASide.Engine\ipaside_engine\vendor\zsign.exe")) {
    throw "vendor\zsign.exe missing. Build it first from MSYS2 MINGW64: bash tools/zsign/build-zsign.sh"
}
Copy-Item "src\iPASide.Engine\ipaside_engine" "$site\ipaside_engine" -Recurse -Force
Get-ChildItem "$site\ipaside_engine" -Recurse -Directory -Filter __pycache__ |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "== Pruning unused heavy dependencies =="
# PyAV (~63 MB of native video codecs) is only used by pymobiledevice3's DVT
# screenshot/video services, which iPASide never calls. Verified the core
# services (installation_proxy/afc/lockdown/usbmux) + every command still import
# without it. (Do NOT prune xonsh - pymobiledevice3's AFC service imports it, and
# pymobiledevice3.utils imports IPython unconditionally, so neither of those goes either.)
$prunePackages = @("av", "av.libs")

# Dead weight inside the installed wheels. Every entry here is either not importable at
# all, or is only reachable behind a try/except the engine never depends on - checked by
# grepping the shipped tree for real importers, then confirmed by the import-surface
# smoke test at the bottom.
$pruneDeadWeight = @(
    # 47.6 MB static link library for the Unicorn CPU emulator anisette drives. The Python
    # binding ctypes-loads lib\unicorn.dll next to it; a .lib is only read by a C linker.
    # Single biggest piece of dead weight in the whole payload.
    "unicorn\lib\unicorn.lib"
    "unicorn\include"
    # pip writes one launcher .exe per console_script of every dependency (41 of them).
    # The engine is always started as `python.exe -m ipaside_engine`, so none ever runs.
    "bin"
    # pywin32's 2.5 MB compiled help file, and Pythonwin - its Tk-era editor application
    # plus the win32ui GUI extension. The only importers of win32ui left in the tree are
    # pywin32's own demos, scripts, tests and makepy's GUI progress class.
    "PyWin32.chm"
    "pythonwin"
    "adodbapi"
    "isapi"
    # Link libraries for compiling C extensions against pywin32.
    "win32\libs"
    "win32com\libs"
    # IPython's optional completion engine (jedi ships a 12 MB typeshed of .pyi stubs).
    # IPython itself has to stay, but IPython\core\completer.py takes jedi inside a
    # try/except and falls back to JEDI_INSTALLED = False, and nothing here ever opens an
    # interactive prompt. parso is jedi's parser and has no other importer.
    "jedi"
    "parso"
    # Only reachable from setup.py files, cffi's C-compiler helpers and unicorn's Python 2
    # shim - none of which run here. The one unguarded importer in the tree,
    # fs.opener.registry, needs pkg_resources, which this engine has never shipped.
    "setuptools"
    # tqdm ships its animated demo GIFs as wheel data, which land in site-packages\images.
    "images"
)
foreach ($item in ($prunePackages + $pruneDeadWeight)) {
    $path = Join-Path $site $item
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
}

Write-Host "== Precompiling bytecode (so first launch doesn't compile ~thousands of .py) =="
& "$eng\python.exe" -m compileall -q -j 0 "$eng\Lib" | Out-Null
$global:LASTEXITCODE = 0

Write-Host "== Smoke test =="
# `version` on its own only proves the interpreter starts. The pruning above is only safe
# if the modules the sideload path actually reaches still import, and those are precisely
# the ones an earlier PyInstaller build broke: pymobiledevice3.utils imports IPython at
# module level, services.afc imports xonsh, and irecv imports pyusb. So import that
# surface explicitly and fail the build if any of it has been cut away.
#
# Deliberately NOT gated on `doctor`: that reports on the machine (Apple Mobile Device
# Service, Bonjour, a paired device) and correctly exits non-zero on a CI runner, so it
# would fail builds for reasons that have nothing to do with the payload.
$surface = @(
    "ipaside_engine.__main__"
    "ipaside_engine.anisette_worker"
    "ipaside_engine.anisette_remote"
    "wsproto"
    "pymobiledevice3.utils"
    "pymobiledevice3.usbmux"
    "pymobiledevice3.lockdown"
    "pymobiledevice3.services.installation_proxy"
    "pymobiledevice3.services.afc"
    "pymobiledevice3.irecv"
    "anisette"
    "unicorn"
    "PIL.Image"
    "cryptography.hazmat.primitives.serialization.pkcs12"
)
$pyList = "[" + (($surface | ForEach-Object { "'$_'" }) -join ",") + "]"
& "$eng\python.exe" -c "import importlib; mods=$pyList; list(map(importlib.import_module, mods)); print(f'{len(mods)} modules import cleanly')"
if ($LASTEXITCODE -ne 0) { throw "engine import surface check failed - something pruned above is still needed" }

& "$eng\python.exe" -m ipaside_engine version
if ($LASTEXITCODE -ne 0) { throw "portable engine smoke test failed" }

$files = Get-ChildItem $dest -Recurse -File
$mb = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 0)
Write-Host "Portable engine ($mb MB, $($files.Count) files) -> $eng\python.exe"
