#Requires -Version 5.1
<#
.SYNOPSIS
    Installs prerequisites for building the AdaptixClient Windows GUI.

.DESCRIPTION
    Installs MSYS2 (via winget), updates its package database, and installs
    the MinGW64 toolchain, Qt6, OpenSSL, CMake, and Ninja required by
    AdaptixC2/AdaptixClient/build.bat.

    Requirements:
      - Windows 10 version 1709 or later, or Windows 11 (winget / App Installer)
      - Administrator privileges (MSYS2 installs to C:\msys64 by default)
      - Internet access (~2 GB download for Qt6 and toolchain)

.PARAMETER Msys2Root
    MSYS2 installation path.  Default: C:\msys64
    This must match the Qt6_DIR value in AdaptixC2/AdaptixClient/CMakeLists.txt
    line 10.  If you change it here, edit that file accordingly before building.

.PARAMETER SkipGit
    Skip installing Git for Windows.  Use if git is already on your PATH.

.EXAMPLE
    # Standard install — from an elevated (Administrator) PowerShell prompt
    # at the repo root:
    powershell -ExecutionPolicy Bypass -File scripts\install-prereqs-windows.ps1

.EXAMPLE
    # Non-default MSYS2 path (also edit CMakeLists.txt line 10 to match):
    powershell -ExecutionPolicy Bypass -File scripts\install-prereqs-windows.ps1 -Msys2Root D:\msys64

.EXAMPLE
    # Skip Git if already installed:
    powershell -ExecutionPolicy Bypass -File scripts\install-prereqs-windows.ps1 -SkipGit

.NOTES
    See BLUEPRINT.md §11 for the full Windows build guide, DLL reference table,
    and known gotchas (ICU version drift, windeployqt PATH, etc.).
#>

[CmdletBinding()]
param(
    [string]$Msys2Root = "C:\msys64",
    [switch]$SkipGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colour helpers ────────────────────────────────────────────────────────────

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Skip { param([string]$m) Write-Host "    [skip] $m" -ForegroundColor DarkGray }
function Write-Warn { param([string]$m) Write-Host "    [warn] $m" -ForegroundColor Yellow }

function Fail {
    param([string]$msg, [string]$hint = "")
    Write-Host "`n[FAIL] $msg" -ForegroundColor Red
    if ($hint) { Write-Host "       $hint" -ForegroundColor Yellow }
    exit 1
}

# Runs a command inside the MSYS2 login shell; fails hard unless -AllowFailure.
# pacman pass 1 is allowed to fail because it may self-terminate after updating
# the MSYS2 core runtime — that is expected behaviour, not an error.
function Invoke-Bash {
    param([string]$cmd, [switch]$AllowFailure)
    & $bash -lc $cmd
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        Fail "bash command exited $LASTEXITCODE" "Command: $cmd"
    }
}

# ── Elevated session check ────────────────────────────────────────────────────

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Must run from an elevated (Administrator) PowerShell prompt." `
         "Right-click PowerShell > 'Run as administrator', then:`n       powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

# ── winget ────────────────────────────────────────────────────────────────────

Write-Step "winget (Windows Package Manager)"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget not found." `
         "Install 'App Installer' from the Microsoft Store and re-run."
}
Write-OK "$(winget --version)"

# ── Git for Windows ───────────────────────────────────────────────────────────

Write-Step "Git for Windows"
if ($SkipGit) {
    Write-Skip "-SkipGit passed"
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Skip "already on PATH: $(git --version)"
} else {
    Write-Host "    Installing Git for Windows..." -ForegroundColor White
    winget install --id Git.Git --source winget `
        --accept-source-agreements --accept-package-agreements --silent

    # Refresh PATH in this session so subsequent steps can see git
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-OK "$(git --version)"
    } else {
        Write-Warn "Installed but not yet on PATH in this session."
        Write-Warn "Open a new prompt after this script completes to use git."
    }
}

# ── MSYS2 ─────────────────────────────────────────────────────────────────────

Write-Step "MSYS2 ($Msys2Root)"
$bash = "$Msys2Root\usr\bin\bash.exe"

if (Test-Path $bash) {
    Write-Skip "Already present at $Msys2Root"
} else {
    Write-Host "    Downloading and installing MSYS2 (~90 MB installer)..." -ForegroundColor White

    if ($Msys2Root -ne "C:\msys64") {
        Write-Warn "Custom path '$Msys2Root' requested."
        Write-Warn "winget may not honour --location for EXE installers; MSYS2 could still"
        Write-Warn "land at C:\msys64.  If so, re-run with: -Msys2Root C:\msys64"
    }

    winget install --id MSYS2.MSYS2 --source winget --location $Msys2Root `
        --accept-source-agreements --accept-package-agreements --silent

    if (-not (Test-Path $bash)) {
        Fail "$bash not found after install." `
             "Re-run with -Msys2Root set to the path where MSYS2 actually installed."
    }
    Write-OK "Installed at $Msys2Root"
}

# ── pacman database update — two passes ───────────────────────────────────────
#
# Pass 1 updates the MSYS2 core runtime.  pacman may self-terminate after this
# step; that is expected and is why -AllowFailure is set.  Pass 2 completes
# any remaining package upgrades.

Write-Step "Updating pacman database — pass 1 of 2"
Write-Host "    pacman may exit early after updating the MSYS2 core; this is normal." -ForegroundColor DarkGray
Invoke-Bash "pacman -Syu --noconfirm" -AllowFailure
Write-OK "Pass 1 complete"

Write-Step "Updating pacman database — pass 2 of 2"
Invoke-Bash "pacman -Syu --noconfirm"
Write-OK "Pass 2 complete"

# ── MinGW64 packages ──────────────────────────────────────────────────────────

Write-Step "Installing MinGW64 packages"

$packages = @(
    "mingw-w64-x86_64-toolchain",  # GCC, G++, binutils, gdb
    "mingw-w64-x86_64-cmake",       # CMake 3.28+
    "mingw-w64-x86_64-ninja",       # Ninja build system (used by build.bat)
    "mingw-w64-x86_64-qt6",         # Qt6: Core Gui Widgets Network WebSockets Sql Qml Svg
    "mingw-w64-x86_64-openssl"      # OpenSSL — statically linked per CMakeLists.txt
)

Write-Host "    Packages : $($packages -join ', ')" -ForegroundColor DarkGray
Write-Host "    Qt6 is ~2 GB — allow 5–15 min on a typical connection." -ForegroundColor DarkGray

Invoke-Bash "pacman -S --needed --noconfirm $($packages -join ' ')"
Write-OK "All packages installed"

# ── Verify binaries ───────────────────────────────────────────────────────────

Write-Step "Verifying MinGW64 binaries"

$mingwBin = "$Msys2Root\mingw64\bin"
$allOk    = $true

$checks = @(
    [pscustomobject]@{ Name = "gcc";     Args = "--version" }
    [pscustomobject]@{ Name = "g++";     Args = "--version" }
    [pscustomobject]@{ Name = "cmake";   Args = "--version" }
    [pscustomobject]@{ Name = "ninja";   Args = "--version" }
    [pscustomobject]@{ Name = "qmake";   Args = "--version" }
    [pscustomobject]@{ Name = "openssl"; Args = "version"   }
)

foreach ($c in $checks) {
    $exe = "$mingwBin\$($c.Name).exe"
    if (Test-Path $exe) {
        $out = & $exe $c.Args.Split(" ") 2>&1 | Select-Object -First 1
        Write-OK "$($c.Name): $out"
    } else {
        Write-Host "    [fail] $($c.Name): $exe not found" -ForegroundColor Red
        $allOk = $false
    }
}

# ── Qt6_DIR alignment check ───────────────────────────────────────────────────

Write-Step "Qt6_DIR / CMakeLists.txt alignment"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$cmakeLists = Join-Path $RepoRoot "AdaptixC2\AdaptixClient\CMakeLists.txt"
if (Test-Path $cmakeLists) {
    $hit = Select-String -Path $cmakeLists -Pattern 'Qt6_DIR' | Select-Object -First 1
    if ($hit) {
        $expectedFragment = $Msys2Root.Replace("\", "/")
        if ($hit.Line -match [regex]::Escape($expectedFragment)) {
            Write-OK "Qt6_DIR in CMakeLists.txt matches $Msys2Root"
        } else {
            Write-Warn "Qt6_DIR mismatch in CMakeLists.txt line $($hit.LineNumber):"
            Write-Host "      Found   : $($hit.Line.Trim())" -ForegroundColor Yellow
            Write-Host "      Expected: a path containing '$expectedFragment'" -ForegroundColor Yellow
            Write-Host "    Edit that line to match before running build.bat." -ForegroundColor Yellow
        }
    }
} else {
    Write-Warn "CMakeLists.txt not found at: $cmakeLists"
    Write-Host "    Submodules may not be initialised — run:" -ForegroundColor Yellow
    Write-Host "    git submodule update --init --recursive" -ForegroundColor Yellow
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
if ($allOk) {
    Write-Host ("─" * 56) -ForegroundColor Green
    Write-Host "  All prerequisites installed and verified." -ForegroundColor Green
    Write-Host ("─" * 56) -ForegroundColor Green
    Write-Host ""
    Write-Host "  To build the client:" -ForegroundColor Cyan
    Write-Host "    cd AdaptixC2\AdaptixClient"
    Write-Host "    build.bat"
    Write-Host "    dist\AdaptixClient.exe"
    Write-Host ""
    Write-Host "  See BLUEPRINT.md §11 for full build details and gotchas." -ForegroundColor DarkGray
} else {
    Write-Host ("─" * 56) -ForegroundColor Red
    Write-Host "  One or more verification checks failed." -ForegroundColor Red
    Write-Host ("─" * 56) -ForegroundColor Red
    Write-Host "  Review the failures above and re-run after resolving them."
    exit 1
}
