# lifsaver

![OS](https://img.shields.io/badge/OS-macOS-lightgrey)
[![CI](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml/badge.svg)](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/lucuma13/lifsaver/graph/badge.svg?token=88HT6VMLHO)](https://codecov.io/gh/lucuma13/lifsaver)

<img src="docs/images/lifsaver_logo_name.svg" width="110" align="left" hspace="10"/>

`lifsaver` addresses a bug on macOS Live Item File System (LIFS) which prevents multiple cards from mounting when they have the same name (e.g. `Untitled` or `NO NAME`). It watches for cards that appear but never mount, and let's you force mount them with two clicks. Please note that whereas this app has been fully tested, you should use it at your own risk.

<br clear="left"/>

<img src="docs/images/lifsaver_demo_animation.gif" width="100%"/>

### 🚀 Installation

Download the latest [installer](https://github.com/lucuma13/lifsaver/releases/latest/download/lifsaver_installer_macos.pkg). Or simply:

```
brew install --cask lucuma13/dit/lifsaver
```

The installer is not notarized – macOS will warn on first open: right-click the .pkg → Open, or allow it under System Settings → Privacy & Security.


### 📖 Background

On modern macOS, external cards mount through the Live Item File System (LIFS), the userspace layer of Apple's LiveFS framework, which handles these volumes via user-space extensions (`livefiles_exfat`, `livefiles_msdos`) instead of kernel extensions.

When two cards carry the same label (e.g. factory default `Untitled`) macOS is supposed to disambiguate them with a numeric suffix (e.g. mount the second card at `/Volumes/Untitled 1`). In practice, on the LIFS path this disambiguation can fail: `diskarbitrationd` probes the volume, begins the mount, then aborts with `unable to mount … (status code 0x00000204)`. The card gets a device node but never finishes mounting – no error dialog, it just doesn't appear in Finder.

`lifsaver` watches for exactly this: a card that appears but stalls before mounting. When it spots one, it first tries `diskutil mount` (which cooperates with LIFS sandboxing and needs no password), and then falls back to the low-level mount binaries (requires admin privileges). It respectfully stands down while macOS is mid consistency-check (`fsck`) on a card, so it never races a repair.

### 🐞 Reporting bugs

If the app misses a stalled card or fails to mount it, please send a diagnostic report: choose *Send Diagnostic Report* from the menu, optionally describe what happened, save the file, then click *Email Report* and send it to me (or open a [GitHub issue](https://github.com/lucuma13/lifsaver/issues/new)).


### ⚠️ Disclaimer

`lifsaver` deliberately circumvents standard macOS Disk Arbitration and LiveFS protections to force-mount stalled volumes. The author assumes no liability for lost or corrupted data, or hardware failures of any kind.
