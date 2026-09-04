<#
.SYNOPSIS
    Disables Discord's built-in auto-updater so it stops silently overwriting BetterDiscord.

.DESCRIPTION
    Discord patches BetterDiscord out every time it auto-updates itself, because the update
    downloads a fresh app build and BD's injection only lives in the previously-patched build.
    This script disables Discord's Squirrel updater (Update.exe) by renaming it, so Discord can
    no longer silently update itself. Discord keeps working normally on the version you're on.

.PARAMETER Channel
    Which Discord channel to target. Default is Stable.

.EXAMPLE
    .\Disable-DiscordUpdater.ps1
    .\Disable-DiscordUpdater.ps1 -Channel PTB
#>
[CmdletBinding()]
param(
    [ValidateSet('Stable', 'PTB', 'Canary', 'Development')]
    [string]$Channel = 'Stable'
)

$folderName = switch ($Channel) {
    'Stable'      { 'Discord' }
    'PTB'         { 'DiscordPTB' }
    'Canary'      { 'DiscordCanary' }
    'Development' { 'DiscordDevelopment' }
}

$updater = Join-Path $env:LOCALAPPDATA "$folderName\Update.exe"
$disabled = "$updater.disabled"

if (Test-Path $disabled) {
    Write-Host "Already locked: $folderName's auto-updater is disabled." -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $updater)) {
    Write-Warning "Update.exe not found at '$updater'. Is $Channel installed for this user?"
    exit 1
}

$proc = Get-Process -Name $folderName -ErrorAction SilentlyContinue
if ($proc) {
    Write-Warning "$folderName is currently running. Close it fully (including the tray icon) before locking, or the rename may fail."
}

try {
    Rename-Item -Path $updater -NewName 'Update.exe.disabled' -ErrorAction Stop
}
catch {
    Write-Error "Could not lock the updater: $($_.Exception.Message)`nMake sure $folderName is fully closed (check the system tray) and try again."
    exit 1
}

Write-Host "Discord ($Channel) is locked. BetterDiscord is now safe from silent auto-update wipes." -ForegroundColor Green
