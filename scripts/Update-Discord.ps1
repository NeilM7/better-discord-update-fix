<#
.SYNOPSIS
    Manually updates Discord and re-injects BetterDiscord in one step, then re-locks the updater.

.DESCRIPTION
    With Discord's auto-updater disabled (see Disable-DiscordUpdater.ps1), Discord will never
    update itself in the background. Run this script whenever you actually want to move to a
    newer Discord build:

      1. Downloads and runs the latest official Discord installer for the chosen channel.
      2. Waits for it to finish and closes Discord.
      3. Re-disables the updater it just reinstated (the installer restores Update.exe).
      4. Uses the official BetterDiscord CLI (bdcli) to re-inject BetterDiscord into the new build.
      5. Relaunches Discord.

    Requires the BetterDiscord CLI (bdcli). Install it with:
        winget install betterdiscord.cli
    or
        npm install -g @betterdiscord/cli
    https://github.com/BetterDiscord/cli

.PARAMETER Channel
    Which Discord channel to update. Default is Stable.

.PARAMETER NoRelaunch
    Skip relaunching Discord after the update.

.EXAMPLE
    .\Update-Discord.ps1
    .\Update-Discord.ps1 -Channel Canary -NoRelaunch
#>
[CmdletBinding()]
param(
    [ValidateSet('Stable', 'PTB', 'Canary')]
    [string]$Channel = 'Stable',

    [switch]$NoRelaunch
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$platformArg = switch ($Channel) {
    'Stable' { 'win' }
    'PTB'    { 'winptb' }
    'Canary' { 'wincanary' }
}
$processName = switch ($Channel) {
    'Stable' { 'Discord' }
    'PTB'    { 'DiscordPTB' }
    'Canary' { 'DiscordCanary' }
}

if (-not (Get-Command bdcli -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "bdcli not found. Installing it via winget..."
        winget install --id betterdiscord.cli -e --accept-source-agreements --accept-package-agreements
        # Refresh PATH for this session so a just-installed bdcli is picked up without reopening the shell.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Get-Command bdcli -ErrorAction SilentlyContinue)) {
        Write-Error "bdcli still not found on PATH. Install it manually: winget install betterdiscord.cli (or) npm install -g @betterdiscord/cli, then re-run this script."
        exit 1
    }
}

Write-Host "Closing $processName if running..."
Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host "Downloading latest Discord installer ($Channel)..."
$installerPath = Join-Path $env:TEMP "DiscordSetup-$Channel.exe"
try {
    Invoke-WebRequest -Uri "https://discord.com/api/download?platform=$platformArg" -OutFile $installerPath -ErrorAction Stop
}
catch {
    Write-Error "Could not download the Discord installer: $($_.Exception.Message)`nCheck your internet connection and try again."
    exit 1
}

Write-Host "Running installer..."
Start-Process -FilePath $installerPath -Wait

# The installer launches Discord itself once done; close it again before re-patching.
Start-Sleep -Seconds 5
Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host "Re-locking the updater..."
& (Join-Path $scriptDir 'Disable-DiscordUpdater.ps1') -Channel $Channel

Write-Host "Re-injecting BetterDiscord..."
bdcli install --channel $($Channel.ToLower())
if ($LASTEXITCODE -ne 0) {
    Write-Warning "bdcli reported an error re-injecting BetterDiscord (exit code $LASTEXITCODE). Discord has still been updated and re-locked; you may need to run 'bdcli install' manually."
}

Remove-Item $installerPath -ErrorAction SilentlyContinue

if (-not $NoRelaunch) {
    $installDir = Join-Path $env:LOCALAPPDATA $(if ($Channel -eq 'Stable') { 'Discord' } else { "Discord$Channel" })
    $appDir = Get-ChildItem -Path $installDir -Filter "app-*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($appDir) {
        Start-Process -FilePath (Join-Path $appDir.FullName "$processName.exe")
    }
    else {
        Write-Warning "Couldn't find the installed app folder to relaunch $processName automatically. Please open it manually."
    }
}

Write-Host "Done. $processName is updated, the updater is locked again, and BetterDiscord is re-injected." -ForegroundColor Green
