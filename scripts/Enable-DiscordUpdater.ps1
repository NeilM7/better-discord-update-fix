<#
.SYNOPSIS
    Re-enables Discord's built-in auto-updater (reverses Disable-DiscordUpdater.ps1).

.PARAMETER Channel
    Which Discord channel to target. Default is Stable.

.EXAMPLE
    .\Enable-DiscordUpdater.ps1
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

if (Test-Path $updater) {
    Write-Host "Already unlocked: $folderName's auto-updater is active." -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $disabled)) {
    Write-Warning "Update.exe.disabled not found at '$disabled'. Nothing to unlock."
    exit 1
}

try {
    Rename-Item -Path $disabled -NewName 'Update.exe' -ErrorAction Stop
}
catch {
    Write-Error "Could not unlock the updater: $($_.Exception.Message)"
    exit 1
}

Write-Host "Discord ($Channel) auto-updater re-enabled." -ForegroundColor Green
