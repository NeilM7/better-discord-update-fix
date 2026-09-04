# BetterDiscord Updater Lock

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D6)](#requirements)

Discord's auto-updater silently overwrites [BetterDiscord](https://betterdiscord.app)'s patch
every time it updates itself in the background, kicking you back to stock Discord with no
warning. This tool stops that from happening — with a double-click, no PowerShell or admin
knowledge required.

It also doubles as a one-click installer: option 3 gets you Discord *and* BetterDiscord from a
completely clean machine, and works just as well to fix a broken/partial BetterDiscord install as
it does for routine updates.

## Contents

- [Quick start](#quick-start-recommended)
- [What the menu does](#what-the-menu-does)
- [How it works](#how-it-works)
- [Running the scripts directly](#advanced-running-the-scripts-directly)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)
- [License](#license)

## Quick start (recommended)

1. [Download the latest release](../../releases/latest) and unzip it anywhere (Desktop is fine).
2. Fully quit Discord (right-click its icon in the system tray, near the clock, and choose Quit —
   closing the window alone isn't enough).
3. Double-click **`BetterDiscordUpdaterLock.bat`**.
4. Choose option **1 — Lock Discord**.

That's it. Discord stays on its current version and BetterDiscord will never get silently wiped
out again.

> **Windows SmartScreen warning:** since this is a small, unsigned script, Windows may show a
> "Windows protected your PC" prompt the first time you run the `.bat`. Click **More info** →
> **Run anyway**. This is normal for any unsigned script downloaded from the internet.

## What the menu does

The launcher shows you the live lock status for every installed Discord channel, then lets you:

| Option | What it does |
|---|---|
| **1. Lock Discord** | Stops Discord from silently auto-updating, so BetterDiscord stays intact. |
| **2. Unlock Discord** | Restores normal auto-update behavior. |
| **3. Install/Update Discord + BetterDiscord** | Gets you fully up to date: downloads and installs the latest Discord (whether it's already installed or not), re-locks the updater, and installs/re-injects BetterDiscord (downloading its own files too if they're not on the machine yet, and installing the [BetterDiscord CLI](https://github.com/BetterDiscord/cli) for you if that's missing). Cleans up its own temp files afterward. Safe to run repeatedly — it always clears out any existing BetterDiscord injection first so a previous partial/broken state can't linger. |
| **4. Choose a different channel** | Switch between Stable, PTB, and Canary. Stable is used by default. |

## How it works

Discord uses Squirrel (`Update.exe` in `%LOCALAPPDATA%\Discord`) to silently download and swap in
new builds. BetterDiscord patches a file inside the *current* build only — so as soon as Squirrel
replaces that build, BD is gone until it's manually re-injected. Locking renames `Update.exe` to
`Update.exe.disabled`; Discord itself keeps working normally on whatever version you're on, it
just can't silently replace itself anymore.

## Advanced: running the scripts directly

Everything the `.bat` does is plain PowerShell in `scripts/`, callable on its own:

| Script | Purpose |
|---|---|
| `scripts/Disable-DiscordUpdater.ps1` | Locks Discord (the permanent fix). |
| `scripts/Enable-DiscordUpdater.ps1` | Unlocks Discord (restores normal auto-update). |
| `scripts/Update-Discord.ps1` | Installs/updates Discord and installs/re-injects BetterDiscord in one step, from any starting state. |
| `scripts/Get-DiscordStatus.ps1` | Prints the current lock status for every installed channel. |

All accept `-Channel Stable|PTB|Canary` (default `Stable`):

```powershell
.\scripts\Disable-DiscordUpdater.ps1 -Channel Canary
```

Quit Discord fully (system tray, not just the window) before running the lock/unlock scripts.

## Requirements

- Windows with PowerShell (built in — no install needed).
- No admin rights — everything is scoped to your own user profile (`%LOCALAPPDATA%`).
- `scripts/Update-Discord.ps1` needs [winget](https://github.com/microsoft/winget-cli) (built into
  modern Windows) to auto-install the BetterDiscord CLI the first time you use option 3.

## Troubleshooting

- **"Update.exe not found"** — Discord (or the channel you picked) isn't installed for your user,
  or it's already locked/unlocked. Check the status line at the top of the menu.
- **Rename fails / "file is in use"** — Discord is still running. Right-click its system tray icon
  and choose Quit, then try again.
- **"bdcli still not found on PATH"** — install it manually with
  `winget install betterdiscord.cli` or `npm install -g @betterdiscord/cli`, then re-run.
- **Option 3 fails with "Access to the path ... is denied" / a shortcut says "Discord.exe has
  been changed or moved"** — a leftover Discord-related process (often the crash handler, or a
  helper process) was still holding a file open when the installer tried to replace it, so the
  install got interrupted partway. This is a well-known Squirrel/Discord quirk and not something
  BetterDiscord Updater Lock caused. `Update-Discord.ps1` already retries once automatically; if
  it still fails, reboot (this always clears stuck file handles) or end every
  Discord/DiscordPTB/DiscordCanary process in Task Manager, then run option 3 again. The broken
  shortcut fixes itself once the update finishes cleanly — you can click "No" if Windows asks to
  delete it.
- **SmartScreen blocks the `.bat`** — click **More info** → **Run anyway**. The scripts are plain
  text; open them in Notepad if you want to see exactly what they do before running.
- **"Cannot find module '../betterdiscord.app.asar'" when Discord starts** — BetterDiscord was
  left in a half-injected state (Discord's entry point was patched to load BetterDiscord's payload
  file, but that file itself is missing or stale, usually because a previous update/injection got
  interrupted). Run option 3 again — it always clears out any existing injection before
  reinstalling, so this resolves itself. If you're running the scripts directly instead of the
  `.bat`, the equivalent manual fix is `bdcli uninstall --channel stable` followed by
  `bdcli install --channel stable` (swap `stable` for `ptb`/`canary` as needed).

## Notes

- Tested against the Stable channel; PTB/Canary support is included but less exercised.
- Not affiliated with Discord Inc. or the BetterDiscord project.

## License

MIT — see [LICENSE](LICENSE).
