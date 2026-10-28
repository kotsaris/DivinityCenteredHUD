<#
.SYNOPSIS
    Builds the mod and installs it into the game's Mods folder.

.DESCRIPTION
    Runs tools/build.py, then copies dist/CenteredHUD.pak into
    Documents\Larian Studios\Divinity Original Sin 2 Definitive Edition\Mods.
    The game keeps loaded .pak files locked, so this refuses to run while
    EoCApp.exe is up instead of failing halfway through the copy.

    Also removes EpipPanelMover.pak, the mod's package before it was renamed;
    both would otherwise load and fight over the same panels.

.PARAMETER ModsDir
    Override the target Mods folder.

.EXAMPLE
    .\tools\deploy.ps1
#>
[CmdletBinding()]
param(
    [string]$ModsDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Larian Studios\Divinity Original Sin 2 Definitive Edition\Mods')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

if (Get-Process -Name 'EoCApp' -ErrorAction SilentlyContinue) {
    throw 'The game is running and locks loaded .pak files. Close it, then deploy again.'
}
if (-not (Test-Path -LiteralPath $ModsDir)) {
    throw "Mods folder not found: $ModsDir"
}

python (Join-Path $repoRoot 'tools\build.py')
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$legacyPak = Join-Path $ModsDir 'EpipPanelMover.pak'
if (Test-Path -LiteralPath $legacyPak) {
    Remove-Item -LiteralPath $legacyPak
    Write-Host "Removed legacy $legacyPak" -ForegroundColor Yellow
}

$pak = Join-Path $repoRoot 'dist\CenteredHUD.pak'
Copy-Item -LiteralPath $pak -Destination $ModsDir -Force
Write-Host "Deployed to $(Join-Path $ModsDir 'CenteredHUD.pak')" -ForegroundColor Cyan
