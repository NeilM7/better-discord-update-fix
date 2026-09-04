<#
.SYNOPSIS
    Reports whether Discord's auto-updater is currently locked or unlocked, for every channel
    that's actually installed.

.DESCRIPTION
    Used by BetterDiscordUpdaterLock.bat to show a live status line in the menu so it's always
    obvious what state Discord is in before you pick an option. Can also be run on its own.

.EXAMPLE
    .\Get-DiscordStatus.ps1
#>
[CmdletBinding()]
param()

$channels = @(
    @{ Name = 'Stable';  Folder = 'Discord' },
    @{ Name = 'PTB';     Folder = 'DiscordPTB' },
    @{ Name = 'Canary';  Folder = 'DiscordCanary' }
)

$found = $false

foreach ($c in $channels) {
    $base = Join-Path $env:LOCALAPPDATA $c.Folder
    $updater = Join-Path $base 'Update.exe'
    $disabled = Join-Path $base 'Update.exe.disabled'

    if (Test-Path $disabled) {
        $found = $true
        Write-Host "  $($c.Name): " -NoNewline
        Write-Host "LOCKED" -ForegroundColor Green -NoNewline
        Write-Host " (BetterDiscord is safe from auto-update wipes)"
    }
    elseif (Test-Path $updater) {
        $found = $true
        Write-Host "  $($c.Name): " -NoNewline
        Write-Host "UNLOCKED" -ForegroundColor Yellow -NoNewline
        Write-Host " (normal auto-update, BetterDiscord can be wiped anytime)"
    }
}

if (-not $found) {
    Write-Host "  No Discord installation found under $env:LOCALAPPDATA." -ForegroundColor DarkGray
}
