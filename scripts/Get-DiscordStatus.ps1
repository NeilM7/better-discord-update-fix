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

    # Only trust a folder that actually has Discord's core runtime files -- Squirrel (Discord's
    # updater) can leave old, incomplete app-* folders behind after a failed cleanup, and sorting
    # folder names as plain text (e.g. "app-1.0.9256" vs "app-1.0.9059") can pick a stale one over
    # the real current version, since 9256 sorts after 9059 as text despite Discord considering
    # 9059 current. Compare the version numbers themselves instead.
    $candidates = Get-ChildItem -Path $base -Filter 'app-*' -Directory -ErrorAction SilentlyContinue
    $validDirs = $candidates | Where-Object {
        (Test-Path (Join-Path $_.FullName 'v8_context_snapshot.bin')) -and
        (Test-Path (Join-Path $_.FullName 'snapshot_blob.bin'))
    }
    $appDir = ($(if ($validDirs) { $validDirs } else { $candidates })) |
        Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
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
