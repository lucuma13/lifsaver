# lifsaver

![OS](https://img.shields.io/badge/OS-macOS-lightgrey)
[![CI](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml/badge.svg)](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/lucuma13/lifsaver/graph/badge.svg?token=88HT6VMLHO)](https://codecov.io/gh/lucuma13/lifsaver)

<img src="docs/images/lifsaver_logo_name.svg" width="110" align="left" hspace="10"/>

`lifsaver` addresses a macOS bug on LIFS (Live Image File System) which prevents multiple cards from mounting when they have the same name (e.g. "Untitled"). It lives in your menu bar and watches for cards that appear but never mount, when that happens you can force-mount the stalled card with two clicks. Please note that whereas this utility has been fully tested, you should use it at your own risk.

<br clear="left"/>

<img src="docs/images/demo.gif" width="100%"/>

### 🚀 Installation

Download the latest [installer](https://github.com/lucuma13/lifsaver/releases/latest/download/lifsaver_installer_macos.pkg). Or simply:

```
brew install --cask lucuma13/dit/lifsaver
```

The installer is not notarized – macOS will warn on first open: right-click the .pkg → Open, or allow it under System Settings → Privacy & Security.

### 📖 Usage

**Menu bar app**. The app watches disk activity and flags any volume that appeared but never mounted:

- The app icon turns orange and a *"Stalled volume detected"* notification appears. Click it, enter your administrator password in the standard macOS dialog, and the cards appear in Finder.
- The menu shows the same state at any time: *"Mount 2 stalled volumes"* when cards are stuck, *"No stalled volumes detected"* otherwise.

**CLI** — same engine, same safety interlocks:

```bash
lifsaver            # scan (read-only), confirm, then mount via sudo
lifsaver --verbose  # show the full mount sequence and raw mount errors
```

### 🐞 Reporting bugs

If `lifsaver` misses a stalled card or fails to mount one, please send a diagnostic report:

- **Menu bar app** — choose *Save Diagnostic Report…* from the menu, optionally describe what happened, save the file, then click *Email Report* and send it to me (or open a [GitHub issue](https://github.com/lucuma13/lifsaver/issues/new)).
- **CLI** — run `lifsaver report`; it saves the report to your `~/Downloads` folder, then email it to me (or open a [GitHub issue](https://github.com/lucuma13/lifsaver/issues/new)).


### ⚠️ Disclaimer

`lifsaver` deliberately circumvents standard macOS Disk Arbitration and LIFS (Live Image File System) protections to force-mount stalled volumes. The author assumes no liability for lost or corrupted data, or hardware failures of any kind.
