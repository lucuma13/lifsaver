<p align="center"><img src="docs/images/lifsaver_logo_name.svg" width="215"/></p>

![OS](https://img.shields.io/badge/OS-macOS-lightgrey)
[![CI](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml/badge.svg)](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/lucuma13/lifsaver/graph/badge.svg?token=88HT6VMLHO)](https://codecov.io/gh/lucuma13/lifsaver)

`lifsaver` addresses a bug on macOS Live Item File System (LIFS) which prevents multiple cards from mounting when they have the same name (e.g. `Untitled` or `NO NAME`). It watches for cards that appear but never mount, and lets you mount them in two clicks.

<img src="docs/images/lifsaver_demo_animation.webp" width="100%" alt="lifsaver menu bar icon demo"/>

### 📖 Background

On macOS, FAT and exFAT cards mount through FSKit and LIFS, the kernel bridge for Apple's LiveFS layer: `diskarbitrationd` picks a mount point (`/Volumes/Untitled`, then `/Volumes/Untitled 1`, …) and hands the mount to `fskitd`. `fskitd` keeps its own table of mounted volumes and refuses any mount whose path is already in that table. When it does, `diskarbitrationd` logs `unable to mount … (status code 0x00000204)` (Cocoa error 516, "a file with the same name already exists") and gives up. The card gets a device node but never finishes mounting – no error dialog, it just doesn't appear in Finder.

The trouble is that `fskitd`'s table can fall out of step with reality. The confirmed trigger is renaming a mounted card in Finder: the card moves from `/Volumes/Untitled` to `/Volumes/A001`, but `fskitd` still records the old path. The next card labelled `Untitled` is offered the now-free `/Volumes/Untitled`, is refused, and so is every later one, until the renamed card is unmounted. Cards that merely share a label mount fine on their own; they only stall once such a stale entry exists.

`lifsaver` watches for exactly this: a card that appears but stalls before mounting. If macOS is mid consistency-check (`fsck`) it holds off rather than race the repair; otherwise, it tries `diskutil mount` and then the raw `/sbin/mount_exfat` and `/sbin/mount_msdos` binaries at a mount point of its own, which sidesteps the stale path (this requires admin privileges).

When a renamed card is behind the stall, `lifsaver` says so and offers to remount that card first: unmounting it makes `fskitd` release the old path, so the stuck card then mounts normally. It never forces the unmount, so a card an offload app is still reading from is left alone. While a renamed card would block the next card with its old label, the menu bar icon shows a notification and the menu offers the remount.

### 🚀 Installation

Download the latest [installer](https://github.com/lucuma13/lifsaver/releases/latest/download/lifsaver_installer_macos.pkg). Or simply:

```
brew install --cask lucuma13/dit/lifsaver
```

The installer is not notarized – macOS will warn on first open: right-click the .pkg → Open, or allow it under System Settings → Privacy & Security.

### 🐞 Reporting bugs

If the app misses a stalled card or fails to mount it, please send a diagnostic report: choose *Send Diagnostic Report* from the menu, optionally describe what happened, save the file, then click *Email Report* and send it to me (or open a [GitHub issue](https://github.com/lucuma13/lifsaver/issues/new)).


### ⚠️ Disclaimer

`lifsaver` deliberately circumvents standard macOS Disk Arbitration and LiveFS protections to force-mount stalled volumes. The author assumes no liability for lost or corrupted data, or hardware failures of any kind. This app is not affiliated with Apple, and you use it at your own risk. 
