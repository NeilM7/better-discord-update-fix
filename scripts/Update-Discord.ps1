<#
.SYNOPSIS
    Installs or updates Discord and (re)injects BetterDiscord in one step, then re-locks the
    updater. Works whether Discord and/or BetterDiscord are already installed, already running,
    partially/incorrectly injected, or not present on this machine at all.

.DESCRIPTION
    With Discord's auto-updater disabled (see Disable-DiscordUpdater.ps1), Discord will never
    update itself in the background. Run this script whenever you want to move to a newer Discord
    build -- or just to get Discord + BetterDiscord onto a brand new machine in one step:

      1. Closes Discord (and every related process) if it's running.
      2. Cleanly uninjects any existing BetterDiscord patch for this channel via `bdcli uninstall`.
         This matters more than it sounds: BetterDiscord patches Discord's entry point to require
         a sibling `betterdiscord.app.asar` file, and if that pairing ever gets out of sync (e.g. a
         previous run was interrupted, or Discord's own auto-updater slipped in before this tool
         got a chance to lock it) Discord fails to start at all with
         "Cannot find module '../betterdiscord.app.asar'". Uninstalling first guarantees a clean
         slate before every reinstall, so this can't happen. Safe to run even if nothing is
         currently installed -- bdcli just reports there was nothing to remove.
      3. Downloads and runs the latest official Discord installer for the chosen channel. This
         works identically whether Discord is already installed (updates it) or not installed at
         all yet (installs it fresh) -- either way you end up on the latest build.
      4. Waits for the install to finish and closes Discord again.
      5. Re-disables the updater the installer just reinstated (the permanent BD-safe lock).
      6. Uses the official BetterDiscord CLI (bdcli) to inject BetterDiscord into the new build.
         bdcli downloads BetterDiscord's own core files itself if they aren't already on the
         machine, so this works for a completely fresh install too, not just re-injection.
      7. Verifies the injection actually took (the BD asar file exists next to Discord's patched
         entry point), not just that bdcli reported success.
      8. Cleans up every temporary file this script created (the downloaded installer, and any
         leftover Squirrel extraction folder).
      9. Relaunches Discord.

    The Discord installer (Squirrel) sometimes fails with "Access to the path ... is denied" if
    any Discord-related process (including its crash handler, or a helper process) still holds a
    file open. This script kills the whole Discord process family before *and* after the
    installer runs, and automatically retries the install once if it looks like it didn't finish
    cleanly.

    Requires the BetterDiscord CLI (bdcli). This script installs it for you via winget if it's
    missing; it can also be installed manually with:
        winget install betterdiscord.cli
    or
        npm install -g @betterdiscord/cli
    https://github.com/BetterDiscord/cli

.PARAMETER Channel
    Which Discord channel to install/update. Default is Stable.

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
$installDir = Join-Path $env:LOCALAPPDATA $processName

function Stop-DiscordFamily {
    <#
        Kills every process that's part of this Discord install: the main app, its GPU/renderer/
        utility subprocesses (they all share the same process name on Windows), the crash handler,
        and any stray Update.exe. Repeats a few times with short waits, because a process that was
        just asked to exit can take a moment to actually release its file handles.
    #>
    param([string]$ProcessName, [string]$InstallDir)

    for ($i = 0; $i -lt 5; $i++) {
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -eq $ProcessName -or
            $_.ProcessName -like "$ProcessName*CrashHandler*" -or
            $_.ProcessName -eq 'Update' -or
            ($InstallDir -and $_.Path -and $_.Path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase))
        }
        if (-not $procs) { return $true }
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # One last check so the caller knows if something is still holding on.
    $stillRunning = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -eq $ProcessName -or
        ($InstallDir -and $_.Path -and $_.Path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase))
    }
    return (-not $stillRunning)
}

function Test-UpdateSucceeded {
    param([string]$InstallDir)
    $appDir = Get-ChildItem -Path $InstallDir -Filter "app-*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    return [bool]$appDir
}

function Get-LatestAppDir {
    param([string]$InstallDir)
    return Get-ChildItem -Path $InstallDir -Filter "app-*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
}

function Test-BetterDiscordInjected {
    <#
        Confirms BetterDiscord is actually wired up in the current app-* folder, not just that
        bdcli exited 0. BetterDiscord injects by making Discord's entry point require a sibling
        betterdiscord*.asar payload; if that payload is missing while the patched entry point still
        references it, Discord won't start ("Cannot find module '../betterdiscord.app.asar'").
    #>
    param([string]$InstallDir)
    $appDir = Get-LatestAppDir -InstallDir $InstallDir
    if (-not $appDir) { return $false }
    $asar = Get-ChildItem -Path (Join-Path $appDir.FullName 'resources') -Filter 'betterdiscord*.asar' -ErrorAction SilentlyContinue
    return [bool]$asar
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

$bdcliChannel = $Channel.ToLower()

Write-Host "Closing $processName (and any related processes) if running..."
Stop-DiscordFamily -ProcessName $processName -InstallDir $installDir | Out-Null

Write-Host "Clearing any existing BetterDiscord injection for a clean reinstall..."
# Do this *before* touching Discord at all, every time -- not just when something looks broken.
# BetterDiscord injects by making Discord's entry point require a sibling betterdiscord*.asar
# file; if a previous run got interrupted (or Discord's own updater slipped in first), that
# pairing can end up mismatched and Discord refuses to start at all. Uninstalling first guarantees
# there's nothing stale left before the fresh install + reinject below. Perfectly safe to run when
# nothing is installed yet -- bdcli just reports there was nothing to remove.
bdcli uninstall --channel $bdcliChannel *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (nothing to clear -- BetterDiscord wasn't injected here yet, which is fine)"
}

Write-Host "Downloading latest Discord installer ($Channel)..."
$installerPath = Join-Path $env:TEMP "DiscordSetup-$Channel.exe"
try {
    Invoke-WebRequest -Uri "https://discord.com/api/download?platform=$platformArg" -OutFile $installerPath -ErrorAction Stop
}
catch {
    Write-Error "Could not download the Discord installer: $($_.Exception.Message)`nCheck your internet connection and try again."
    exit 1
}

$maxAttempts = 2
$succeeded = $false

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Host "Closing $processName (and any related processes) if running..."
    $clean = Stop-DiscordFamily -ProcessName $processName -InstallDir $installDir
    if (-not $clean) {
        Write-Warning "Some $processName-related processes wouldn't close. The install may fail with an access-denied error -- if it does, close them manually in Task Manager (or reboot) and re-run this script."
    }

    Write-Host "Running installer (attempt $attempt of $maxAttempts)..."
    # Don't use -Wait: Discord's installer (Squirrel) reliably finishes the install and relaunches
    # Discord itself, but the installer process doesn't always exit afterwards -- -Wait would then
    # block forever even though there's nothing left to do. Instead, poll: the install is done as
    # soon as either the installer process exits on its own, or Discord itself comes back up.
    $proc = Start-Process -FilePath $installerPath -PassThru
    $timeoutSeconds = 180
    $waited = 0
    $installerExitCode = $null

    while ($waited -lt $timeoutSeconds) {
        Start-Sleep -Seconds 3
        $waited += 3

        if ($proc.HasExited) {
            $installerExitCode = $proc.ExitCode
            break
        }
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            Write-Host "$processName has relaunched -- the update finished."
            $installerExitCode = 0
            break
        }
    }

    if ($null -eq $installerExitCode) {
        Write-Warning "The installer didn't finish (or relaunch $processName) within $timeoutSeconds seconds. Treating this attempt as failed."
    }
    elseif (-not $proc.HasExited) {
        # Discord came back up but the installer itself is still sitting there for some reason --
        # it has nothing left to do, so don't leave it running in the background.
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }

    # Close Discord again (whether the installer relaunched it or not) before re-patching.
    Stop-DiscordFamily -ProcessName $processName -InstallDir $installDir | Out-Null

    if ((Test-UpdateSucceeded -InstallDir $installDir) -and $installerExitCode -eq 0) {
        $succeeded = $true
        break
    }

    if ($attempt -lt $maxAttempts) {
        Write-Warning "The install didn't look clean (installer exit code $installerExitCode). This is usually a transient file lock. Waiting a few seconds and trying once more..."
        Start-Sleep -Seconds 5
    }
}

if (-not $succeeded) {
    Write-Error @"
The Discord installer did not complete successfully after $maxAttempts attempt(s).
This is almost always a file that's still locked by another process (a lingering Discord
process, or antivirus briefly scanning the new files).

Try this:
  1. Reboot (this reliably releases any stuck file handles), or manually end every
     Discord/DiscordPTB/DiscordCanary process in Task Manager.
  2. Re-run this script (or option 3 in BetterDiscordUpdaterLock.bat).

If a desktop/taskbar shortcut now shows "this shortcut refers to Discord.exe which has been
changed or moved", that's a side effect of the interrupted install, not a separate problem --
it'll resolve itself once the update finishes cleanly. You can safely click "No" to keep it.
"@
    Remove-Item $installerPath -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Re-locking the updater..."
& (Join-Path $scriptDir 'Disable-DiscordUpdater.ps1') -Channel $Channel

Write-Host "Installing/re-injecting BetterDiscord (downloads BetterDiscord's own files too if they aren't on this machine yet)..."
bdcli install --channel $bdcliChannel
$bdcliExitCode = $LASTEXITCODE

if ($bdcliExitCode -ne 0) {
    Write-Warning "bdcli reported an error (exit code $bdcliExitCode) injecting BetterDiscord. Discord has still been updated and re-locked; you may need to run 'bdcli install --channel $bdcliChannel' manually."
}
elseif (-not (Test-BetterDiscordInjected -InstallDir $installDir)) {
    Write-Warning @"
bdcli reported success, but BetterDiscord's payload file couldn't be found next to Discord's
patched entry point afterwards -- Discord may fail to start with a "Cannot find module" error.
Try running 'bdcli uninstall --channel $bdcliChannel' followed by 'bdcli install --channel $bdcliChannel' manually.
"@
}
else {
    Write-Host "BetterDiscord injection verified." -ForegroundColor Green
}

Write-Host "Cleaning up temporary files..."
Remove-Item $installerPath -ErrorAction SilentlyContinue
# Squirrel (Discord's installer/updater) extracts to a scratch folder here and doesn't always
# clean it up itself.
Get-ChildItem -Path $env:LOCALAPPDATA -Filter 'SquirrelTemp*' -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

if (-not $NoRelaunch) {
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
