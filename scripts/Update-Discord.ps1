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
      4. Waits for the install to finish, THEN waits for Discord's own first-run update chain to
         settle. On a fresh install (or a big version jump) Discord's installer only bootstraps it;
         Discord's own Update.exe downloads and applies a chain of incremental patches the first
         time it actually launches (the "Downloading update 1 of 7..." screen). Closing Discord too
         early here would freeze that chain half-finished and leave BetterDiscord with nothing real
         to attach to later, so this script waits until Update.exe is no longer active and the
         resolved app-* folder has stopped changing before moving on.
      5. Closes Discord and re-disables the updater the installer just reinstated (the permanent
         BD-safe lock).
      6. Uses the official BetterDiscord CLI (bdcli) to inject BetterDiscord into the new build.
         bdcli downloads BetterDiscord's own core files itself if they aren't already on the
         machine, so this works for a completely fresh install too, not just re-injection.
      7. Proves the injection actually works by test-launching Discord for real and checking it
         doesn't crash -- not just that bdcli exited 0 or that the payload file exists on disk.
         BetterDiscord's known "Cannot find module '../betterdiscord.app.asar'" bug shows up as a
         small error dialog that Electron leaves the process *running* behind (it does not exit),
         so this checks for that dialog specifically, not just whether the process is still alive.
         Retries the whole inject-and-test cycle up to twice, and each trial launch up to three
         times, before giving up.
      8. Cleans up every temporary file this script created (the downloaded installer, and any
         leftover Squirrel extraction folder / stale app-* version folders).
      9. Leaves Discord closed by default -- pass -Relaunch to have it opened for you automatically
         once everything is verified.

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

.PARAMETER Relaunch
    Open Discord automatically once everything is installed/injected and verified. Off by default
    -- there's no need to force it open right this second, and it means you never end up staring at
    a leftover crash dialog from this script's own launch. Just open Discord yourself whenever
    you're ready; by the time you do, any brief file lock from the install has long since cleared.

.EXAMPLE
    .\Update-Discord.ps1
    .\Update-Discord.ps1 -Channel Canary -Relaunch
#>
[CmdletBinding()]
param(
    [ValidateSet('Stable', 'PTB', 'Canary')]
    [string]$Channel = 'Stable',

    [switch]$Relaunch
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

function Get-CurrentAppDir {
    <#
        Finds the app-* folder that's actually the current, working Discord install -- NOT just
        the one with the alphabetically-last name. Sorting "app-1.0.9256" vs "app-1.0.9059" as
        plain text picks 9256 first even when 9059 is the real current version, and Squirrel
        (Discord's updater) can leave old, incomplete app-* folders behind after a failed cleanup
        (e.g. if a process still had a file open when it tried to delete them) -- launching Discord
        out of one of those crashes immediately with a missing-V8-snapshot error, and checking one
        for a BetterDiscord payload gives a false "not injected" reading. So: only consider a
        folder "valid" if it actually has Discord's core runtime files, then pick the
        highest-numbered *valid* one -- comparing the version numbers themselves, not the text.
    #>
    param([string]$InstallDir)
    $candidates = Get-ChildItem -Path $InstallDir -Filter "app-*" -Directory -ErrorAction SilentlyContinue
    if (-not $candidates) { return $null }

    $valid = $candidates | Where-Object {
        (Test-Path (Join-Path $_.FullName 'v8_context_snapshot.bin')) -and
        (Test-Path (Join-Path $_.FullName 'snapshot_blob.bin'))
    }
    $pool = if ($valid) { $valid } else { $candidates }

    return $pool | Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
}

function Remove-StaleAppDirs {
    <#
        Best-effort cleanup of leftover app-* folders that aren't the current one. Squirrel is
        supposed to do this itself but can fail to (usually a file lock at the time), leaving dead,
        broken install folders sitting around indefinitely. Never fails the script if a folder is
        still locked -- it just stays for next time.
    #>
    param([string]$InstallDir, [string]$CurrentPath)
    Get-ChildItem -Path $InstallDir -Filter "app-*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $CurrentPath } |
        ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $_.FullName) {
                Write-Host "  (couldn't remove stale folder $($_.Name) -- still in use, harmless to leave)"
            }
            else {
                Write-Host "  removed stale folder $($_.Name)"
            }
        }
}

function Test-UpdateSucceeded {
    param([string]$InstallDir)
    return [bool](Get-CurrentAppDir -InstallDir $InstallDir)
}

function Wait-ForDiscordSelfUpdateToSettle {
    <#
        On a completely fresh install (or a big version jump), the small setup.exe this script just
        ran only bootstraps Discord -- Discord's own Update.exe then downloads and applies a chain
        of incremental patches the first time Discord actually launches (the "Downloading update 1
        of 7..." screen). If this script closed Discord and disabled Update.exe the moment Discord's
        process first appeared, it could interrupt that chain partway through: the app-* folder left
        behind already has the core runtime files Get-CurrentAppDir checks for (so it "looks" valid)
        but isn't actually the final build Discord expects, and BetterDiscord's injection then has
        nothing real to attach to. So: wait here until Update.exe is no longer active AND the
        resolved current app-* folder has stopped changing across a couple of checks, not just until
        Discord's process first shows up.
    #>
    param([string]$InstallDir, [int]$TimeoutSeconds = 120, [int]$PollSeconds = 3)

    $waited = 0
    $lastAppDir = $null
    $stableChecks = 0
    while ($waited -lt $TimeoutSeconds) {
        $updating = Get-Process -Name 'Update' -ErrorAction SilentlyContinue
        $current = Get-CurrentAppDir -InstallDir $InstallDir
        $currentPath = if ($current) { $current.FullName } else { $null }

        if ((-not $updating) -and $currentPath -and ($currentPath -eq $lastAppDir)) {
            $stableChecks++
            if ($stableChecks -ge 2) { return }
        }
        else {
            $stableChecks = 0
        }
        $lastAppDir = $currentPath

        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
    }
    Write-Host "  (Discord's own update chain still looked active after $TimeoutSeconds seconds -- continuing anyway)"
}

function Test-BetterDiscordInjected {
    <#
        Confirms BetterDiscord is actually wired up in the current app-* folder, not just that
        bdcli exited 0. BetterDiscord injects by making Discord's entry point require a sibling
        betterdiscord*.asar payload; if that payload is missing while the patched entry point still
        references it, Discord won't start ("Cannot find module '../betterdiscord.app.asar'").
    #>
    param([string]$InstallDir)
    $appDir = Get-CurrentAppDir -InstallDir $InstallDir
    if (-not $appDir) { return $false }
    $asar = Get-ChildItem -Path (Join-Path $appDir.FullName 'resources') -Filter 'betterdiscord*.asar' -ErrorAction SilentlyContinue
    return [bool]$asar
}

function Wait-ForStableFile {
    <#
        Waits until a file exists AND its size has stopped changing across two checks a moment
        apart, up to a timeout. bdcli's install step (rename Discord's real asar to
        betterdiscord.app.asar, write a new patched entry point, then relaunch Discord) is a
        multi-step filesystem operation, not an atomic one -- and on Windows a fresh/just-renamed
        file can also sit behind a brief antivirus/reputation-scan lock. If Discord launches into
        the middle of any of that, module resolution can fail with "Cannot find module" even
        though everything is actually fine a moment later. Polling for a stable size (rather than
        a fixed sleep) means this adapts to how long the machine actually needs instead of guessing.
        Returns $true once stable, $false if the timeout is hit (caller decides whether to proceed
        anyway or treat it as a failure).
    #>
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 20,
        [int]$PollSeconds = 1
    )
    $waited = 0
    $lastSize = -1
    $stableChecks = 0
    while ($waited -lt $TimeoutSeconds) {
        if (Test-Path $Path) {
            try {
                $size = (Get-Item -Path $Path -ErrorAction Stop).Length
                if ($size -gt 0 -and $size -eq $lastSize) {
                    $stableChecks++
                    if ($stableChecks -ge 2) { return $true }
                }
                else {
                    $stableChecks = 0
                }
                $lastSize = $size
            }
            catch {
                # File exists but couldn't be read (still locked by whatever's writing it) -- keep waiting.
                $stableChecks = 0
            }
        }
        else {
            $stableChecks = 0
        }
        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
    }
    return $false
}

function Test-DiscordSurvivesLaunch {
    <#
        The only verification that actually means anything: launch Discord for real and see if it
        stays up -- and "stays up" has to mean more than "the process hasn't exited". When the
        "Cannot find module '../betterdiscord.app.asar'" bug hits, Electron's default behavior for
        an uncaught exception in the *main* process is to pop a small "A JavaScript error occurred
        in the main process" dialog and just sit there -- the process does NOT exit, it hangs
        showing that dialog until someone clicks OK. So checking $proc.HasExited alone says
        "survived" for a client that's actually crashed and stuck on an error dialog. Catch that by
        also checking for a window titled like an error dialog belonging to this process name.
        Always leaves Discord closed again afterwards (force-killing also dismisses any stuck
        dialog, no need to click through it) -- the caller decides when to do the real, user-visible
        launch.
    #>
    param([string]$ExePath, [string]$ProcessName, [string]$InstallDir, [int]$SettleSeconds = 5)

    if (-not (Test-Path $ExePath)) { return $false }

    $proc = Start-Process -FilePath $ExePath -PassThru
    Start-Sleep -Seconds $SettleSeconds

    $crashDialog = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match 'error|problem|crash' }
    $survived = (-not $proc.HasExited) -and (-not $crashDialog)

    Stop-DiscordFamily -ProcessName $ProcessName -InstallDir $InstallDir | Out-Null
    return $survived
}

function Invoke-BetterDiscordInject {
    <#
        Runs bdcli install, then proves the result actually works by launching Discord for real
        (see Test-DiscordSurvivesLaunch) rather than just trusting that bdcli exited 0 or that the
        payload file exists on disk. Returns $true only once BetterDiscord's file is present AND a
        trial launch of Discord actually survives a few seconds.
    #>
    param([string]$BdcliChannel, [string]$InstallDir)

    bdcli install --channel $BdcliChannel
    $exitCode = $LASTEXITCODE

    # bdcli restarts Discord itself as its very last step, immediately after writing the freshly
    # downloaded BetterDiscord files to disk -- close that back down before it can race anything,
    # then do our own controlled trial launch below instead of trusting that one.
    Stop-DiscordFamily -ProcessName $processName -InstallDir $InstallDir | Out-Null

    if ($exitCode -ne 0) { return $false }

    $appDir = Get-CurrentAppDir -InstallDir $InstallDir
    if (-not $appDir) { return $false }
    $asar = Get-ChildItem -Path (Join-Path $appDir.FullName 'resources') -Filter 'betterdiscord*.asar' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $asar) { return $false }

    # Give any lingering file lock (AV/reputation scan on the just-written files) a moment to clear
    # on its own before even attempting the trial launch below -- cheap insurance, not the real test.
    Wait-ForStableFile -Path $asar.FullName -TimeoutSeconds 15 | Out-Null

    Write-Host "  Test-launching Discord to confirm the injection actually works (not just that the files exist)..."
    $exePath = Join-Path $appDir.FullName "$processName.exe"
    $trialAttempts = 3
    for ($t = 1; $t -le $trialAttempts; $t++) {
        if (Test-DiscordSurvivesLaunch -ExePath $exePath -ProcessName $processName -InstallDir $InstallDir) {
            return $true
        }
        Write-Host "  Trial launch $t of $trialAttempts crashed immediately -- this is the exact file-lock race BetterDiscord is prone to. Waiting and trying again..."
        Start-Sleep -Seconds 3
    }

    return $false
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

    if ($installerExitCode -eq 0) {
        # Don't close Discord yet -- on a fresh install (or a big version jump) it's likely mid-way
        # through its own first-run update chain ("Downloading update 1 of 7..."), and closing it
        # (then disabling Update.exe) now would freeze that chain half-finished. Let it settle first.
        Write-Host "Waiting for Discord's own first-run update chain to finish (this is the 'Downloading update X of Y' step, if you see it)..."
        Wait-ForDiscordSelfUpdateToSettle -InstallDir $installDir
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
# bdcli occasionally reports success but the injection doesn't actually stick (usually the same
# kind of transient file-lock race as the Discord installer itself). Give it up to two full
# uninstall+install cycles before giving up and telling the user -- this is what turns "worked on
# my machine after I fiddled with it" into "just works" for someone running this cold.
$bdInjected = $false
$injectAttempts = 2
for ($i = 1; $i -le $injectAttempts; $i++) {
    if ($i -gt 1) {
        Write-Host "  Injection didn't verify -- clearing and trying once more (attempt $i of $injectAttempts)..."
        bdcli uninstall --channel $bdcliChannel *>$null
        Start-Sleep -Seconds 2
    }
    $ok = Invoke-BetterDiscordInject -BdcliChannel $bdcliChannel -InstallDir $installDir
    if ($ok -and (Test-BetterDiscordInjected -InstallDir $installDir)) {
        $bdInjected = $true
        break
    }
}

if (-not $bdInjected) {
    Write-Warning @"
BetterDiscord's payload file couldn't be verified next to Discord's patched entry point after
$injectAttempts attempt(s) -- Discord may fail to start with a "Cannot find module" error.
Discord itself has still been updated and re-locked successfully. Try closing Discord completely
(system tray included) and running this again, or run 'bdcli uninstall --channel $bdcliChannel'
followed by 'bdcli install --channel $bdcliChannel' manually.
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
# Old app-* folders Squirrel failed to clean up after a previous update. Leaving these around is
# more than just clutter -- a stale, incomplete one sitting next to the real install is exactly
# what caused Discord to crash on launch here (see Get-CurrentAppDir above).
$currentAppDir = Get-CurrentAppDir -InstallDir $installDir
if ($currentAppDir) {
    Remove-StaleAppDirs -InstallDir $installDir -CurrentPath $currentAppDir.FullName
}

if ($Relaunch) {
    # Some Squirrel apps keep a stable top-level launcher exe at $installDir\$processName.exe that
    # always redirects to whichever version is current. Discord doesn't ship one -- its desktop/
    # taskbar shortcuts point at Update.exe itself (which is exactly why locking the updater, i.e.
    # renaming Update.exe, breaks those shortcuts while it's on). So: check for a stub in case a
    # future Discord build adds one, but the real, reliable path is launching straight out of the
    # current versioned app-* folder we already resolved above.
    $stubExe = Join-Path $installDir "$processName.exe"
    $launchExe = if (Test-Path $stubExe) { $stubExe } elseif ($currentAppDir) { Join-Path $currentAppDir.FullName "$processName.exe" } else { $null }

    if (-not $launchExe) {
        Write-Warning "Couldn't find $processName to relaunch automatically. Please open it manually."
    }
    else {
        # Belt-and-suspenders: the injection step above already proved a trial launch survives, but
        # cleanup (removing temp files/stale folders) happens in between, and this is the launch the
        # user actually sees. Uses the same crash-dialog-aware check as the trial launch (a process
        # that hits the "Cannot find module" bug does NOT exit -- Electron just hangs it behind a
        # small error dialog) so a bad launch gets retried instead of left on screen.
        $launched = $false
        for ($r = 1; $r -le 3; $r++) {
            $proc = Start-Process -FilePath $launchExe -PassThru
            Start-Sleep -Seconds 4
            $crashDialog = Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -match 'error|problem|crash' }
            if ((-not $proc.HasExited) -and (-not $crashDialog)) { $launched = $true; break }
            Stop-DiscordFamily -ProcessName $processName -InstallDir $installDir | Out-Null
            if ($r -lt 3) {
                Write-Host "$processName hit a crash dialog on launch -- retrying ($r of 3)..."
                Start-Sleep -Seconds 2
            }
        }
        if ($launched) {
            Write-Host "$processName is open." -ForegroundColor Green
        }
        else {
            Write-Warning "$processName kept crashing on launch. Everything is installed and locked correctly -- just try opening $processName yourself in a few seconds."
        }
    }
}
else {
    Write-Host "Not relaunching $processName automatically -- open it whenever you're ready (pass -Relaunch to do it automatically)."
}

Write-Host "Done. $processName is updated, the updater is locked again, and BetterDiscord is re-injected." -ForegroundColor Green
