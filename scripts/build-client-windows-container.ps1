#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the AdaptixClient Windows GUI inside a Windows Docker container.

.DESCRIPTION
    Uses docker/Dockerfile.windows-client to install MSYS2 + MinGW64 + Qt6 inside
    a Windows Server Core container, build AdaptixClient.exe, run windeployqt,
    and copy the deployed client tree to AdaptixClient-dist\windows.

    Docker Desktop must be running in Windows container mode. Pass
    -SwitchToWindowsEngine to ask Docker Desktop to switch engines before the
    build. Switching engines is global to Docker Desktop and will interrupt Linux
    containers while the daemon restarts.
#>

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SwitchToWindowsEngine,
    [string]$ImageTag = "adaptixc2-omni-client-windows:latest",
    [string]$WindowsBaseImage = "mcr.microsoft.com/windows/servercore:ltsc2022",
    [string]$Msys2ArchiveUrl = "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-OK { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
function Fail {
    param([string]$Message, [string]$Hint = "")
    Write-Host "`n[FAIL] $Message" -ForegroundColor Red
    if ($Hint) { Write-Host "       $Hint" -ForegroundColor Yellow }
    exit 1
}

function Get-DockerOsType {
    $osType = (& docker info --format '{{.OSType}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($osType)) {
        return $null
    }
    return $osType.Trim()
}

function Wait-DockerOsType {
    param(
        [Parameter(Mandatory=$true)][string]$Expected,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $current = Get-DockerOsType
        if ($current -eq $Expected) {
            return
        }
        Write-Host "    waiting for Docker engine ($current -> $Expected)..." -ForegroundColor DarkGray
    } while ((Get-Date) -lt $deadline)

    Fail "Timed out waiting for Docker engine to report '$Expected'."
}

function Test-McrConnectivity {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        return
    }

    & cmd.exe /c "curl.exe -4 -fsSI https://mcr.microsoft.com/v2/ >NUL 2>NUL"
    $ipv4Ok = ($LASTEXITCODE -eq 0)
    & cmd.exe /c "curl.exe -6 -fsSI https://mcr.microsoft.com/v2/ >NUL 2>NUL"
    $ipv6Ok = ($LASTEXITCODE -eq 0)

    if ($ipv4Ok -and -not $ipv6Ok) {
        Write-Host "    [warn] MCR works over IPv4 but fails over IPv6 on this host." -ForegroundColor Yellow
        Write-Host "           If the base-image pull fails with wsarecv/reset, make Windows prefer IPv4" -ForegroundColor Yellow
        Write-Host "           for MCR or disable broken IPv6 on the active network path, then retry." -ForegroundColor Yellow
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$Dockerfile = Join-Path $RepoRoot "docker\Dockerfile.windows-client"
$DistRoot = Join-Path $RepoRoot "AdaptixClient-dist"
$DistDir = Join-Path $DistRoot "windows"

Write-Step "Preflight"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "docker is not on PATH." "Restart PowerShell after installing Docker Desktop, or add Docker's resources\bin directory to PATH."
}
if (-not (Test-Path $Dockerfile)) {
    Fail "Missing Dockerfile: $Dockerfile"
}
if (-not (Test-Path (Join-Path $RepoRoot "AdaptixC2\AdaptixClient\CMakeLists.txt"))) {
    Fail "AdaptixC2 submodule is not initialized." "Run: git submodule update --init --recursive"
}

$osType = Get-DockerOsType
if (-not $osType) {
    Fail "Docker Desktop is not responding." "Start Docker Desktop and retry."
}
Write-OK "Docker engine: $osType"
Test-McrConnectivity

if ($osType -ne "windows") {
    if (-not $SwitchToWindowsEngine) {
        Fail "Docker Desktop is currently using '$osType' containers." `
             "Switch to Windows containers, or re-run with -SwitchToWindowsEngine. This is a global Docker Desktop switch."
    }

    $dockerCli = Join-Path ${env:ProgramFiles} "Docker\Docker\DockerCli.exe"
    if (-not (Test-Path $dockerCli)) {
        Fail "DockerCli.exe not found at $dockerCli." "Use Docker Desktop's tray menu: Switch to Windows containers."
    }

    Write-Step "Switching Docker Desktop to Windows containers"
    & $dockerCli -SwitchWindowsEngine
    Wait-DockerOsType -Expected "windows"
    Write-OK "Docker engine: windows"
}

if ($Clean -and (Test-Path $DistDir)) {
    Write-Step "Cleaning $DistDir"
    Remove-Item -LiteralPath $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Force $DistRoot | Out-Null

Write-Step "Building Windows client image"
& docker build `
    --file $Dockerfile `
    --tag $ImageTag `
    --build-arg "WINDOWS_BASE_IMAGE=$WindowsBaseImage" `
    --build-arg "MSYS2_ARCHIVE_URL=$Msys2ArchiveUrl" `
    $RepoRoot
if ($LASTEXITCODE -ne 0) {
    Fail "docker build failed."
}

Write-Step "Extracting C:\client-dist"
$containerName = "adaptixc2-omni-client-windows-copy"
& cmd.exe /c "docker rm -f $containerName >NUL 2>NUL"
& docker create --name $containerName $ImageTag | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "Could not create extraction container from $ImageTag."
}

try {
    if (Test-Path $DistDir) {
        Remove-Item -LiteralPath $DistDir -Recurse -Force
    }
    & docker cp "${containerName}:C:\client-dist" $DistDir
    if ($LASTEXITCODE -ne 0) {
        Fail "docker cp failed."
    }
}
finally {
    & cmd.exe /c "docker rm -f $containerName >NUL 2>NUL"
}

$exe = Join-Path $DistDir "AdaptixClient.exe"
if (-not (Test-Path $exe)) {
    Fail "Build finished but AdaptixClient.exe was not found in $DistDir."
}

$size = (Get-Item $exe).Length / 1MB
Write-Host ""
Write-Host ("-" * 56) -ForegroundColor Green
Write-Host "  Done. Windows client staged at:" -ForegroundColor Green
Write-Host "  $DistDir" -ForegroundColor Green
Write-Host ("-" * 56) -ForegroundColor Green
Write-Host ("  AdaptixClient.exe: {0:N1} MB" -f $size) -ForegroundColor DarkGray
