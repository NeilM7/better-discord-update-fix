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

    The Discord installer (Squirrel) sometimes fails with "Access to the path ... is denied" if
    any Discord-related process (including its crash handler, or a helper process) still holds a
    file open. This script kills the whole Discord process family before *and* after the
    installer runs, and automatically retries the install once if it looks like it didn't finish
    cleanly.

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
        Write-Warning "Some $processName-related processes wouldn't close. The install may fail with an access-denied error — if it does, close them manually in Task Manager (or reboot) and re-run this script."
    }

    Write-Host "Running installer (attempt $attempt of $maxAttempts)..."
    $proc = Start-Process -FilePath $installerPath -PassThru -Wait
    Start-Sleep -Seconds 3

    # The installer launches Discord itself once done; close it again before re-patching.
    Stop-DiscordFamily -ProcessName $processName -InstallDir $installDir | Out-Null

    if ((Test-UpdateSucceeded -InstallDir $installDir) -and $proc.ExitCode -eq 0) {
        $succeeded = $true
        break
    }

    if ($attempt -lt $maxAttempts) {
        Write-Warning "The install didn't look clean (installer exit code $($proc.ExitCode)). This is usually a transient file lock. Waiting a few seconds and trying once more..."
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

Write-Host "Re-injecting BetterDiscord..."
bdcli install --channel $($Channel.ToLower())
if ($LASTEXITCODE -ne 0) {
    Write-Warning "bdcli reported an error re-injecting BetterDiscord (exit code $LASTEXITCODE). Discord has still been updated and re-locked; you may need to run 'bdcli install' manually."
}

Remove-Item $installerPath -ErrorAction SilentlyContinue

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
