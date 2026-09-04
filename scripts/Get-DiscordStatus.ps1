<#
.SYNOPSIS
    Reports whether Discord's auto-updater is locked, and whether BetterDiscord is actually
    injected, for every channel that's installed.

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

    $lockState = $null
    if (Test-Path $disabled) {
        $lockState = 'locked'
    }
    elseif (Test-Path $updater) {
        $lockState = 'unlocked'
    }
    if (-not $lockState) { continue }

    $found = $true

    $appDir = Get-ChildItem -Path $base -Filter 'app-*' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    $bdInjected = $false
    if ($appDir) {
        $bdAsar = Get-ChildItem -Path (Join-Path $appDir.FullName 'resources') -Filter 'betterdiscord*.asar' -ErrorAction SilentlyContinue
        $bdInjected = [bool]$bdAsar
    }

    Write-Host "  $($c.Name): " -NoNewline
    if ($lockState -eq 'locked') {
        Write-Host "LOCKED" -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host "UNLOCKED" -ForegroundColor Yellow -NoNewline
    }
    Write-Host " | BetterDiscord: " -NoNewline
    if ($bdInjected) {
        Write-Host "injected" -ForegroundColor Green
    }
    else {
        Write-Host "NOT injected (run option 3)" -ForegroundColor Yellow
    }
}

if (-not $found) {
    Write-Host "  No Discord installation found under $env:LOCALAPPDATA." -ForegroundColor DarkGray
}
