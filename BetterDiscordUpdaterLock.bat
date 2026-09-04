@echo off
setlocal
title BetterDiscord Updater Lock
set "SCRIPTS=%~dp0scripts"

:menu
cls
echo ================================================
echo   BetterDiscord Updater Lock
echo ================================================
echo.
echo   Current status:
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTS%\Get-DiscordStatus.ps1"
echo.
echo ------------------------------------------------
echo   1. Lock Discord     (stop it from erasing BetterDiscord)
echo   2. Unlock Discord   (restore normal auto-update)
echo   3. Install/Update Discord + BetterDiscord (works from scratch too)
echo   4. Choose a different channel (Stable / PTB / Canary)
echo   5. Exit
echo ------------------------------------------------
echo.
set /p choice="Choose an option (1-5): "

if "%choice%"=="1" goto lock
if "%choice%"=="2" goto unlock
if "%choice%"=="3" goto update
if "%choice%"=="4" goto choose_channel
if "%choice%"=="5" goto end
echo.
echo   Not a valid option, try again.
timeout /t 2 >nul
goto menu

:choose_channel
cls
echo ================================================
echo   Choose a Discord channel
echo ================================================
echo.
echo   1. Stable  (default, what most people use)
echo   2. PTB
echo   3. Canary
echo   4. Back
echo.
set /p chan_choice="Choose an option (1-4): "
if "%chan_choice%"=="1" set "CHANNEL=Stable" & goto menu
if "%chan_choice%"=="2" set "CHANNEL=PTB" & goto menu
if "%chan_choice%"=="3" set "CHANNEL=Canary" & goto menu
if "%chan_choice%"=="4" goto menu
goto choose_channel

:lock
if not defined CHANNEL set "CHANNEL=Stable"
echo.
echo   Locking Discord (%CHANNEL%)...
echo   Make sure Discord is fully closed (check the system tray) first.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTS%\Disable-DiscordUpdater.ps1" -Channel %CHANNEL%
goto pause_menu

:unlock
if not defined CHANNEL set "CHANNEL=Stable"
echo.
echo   Unlocking Discord (%CHANNEL%)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTS%\Enable-DiscordUpdater.ps1" -Channel %CHANNEL%
goto pause_menu

:update
if not defined CHANNEL set "CHANNEL=Stable"
echo.
echo   Installing/updating Discord (%CHANNEL%) and BetterDiscord...
echo   This works whether either one is already installed or not, and downloads
echo   whatever's needed. May take a few minutes on a fresh machine.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTS%\Update-Discord.ps1" -Channel %CHANNEL%
goto pause_menu

:pause_menu
echo.
pause
goto menu

:end
endlocal
