# lifsaver

![OS](https://img.shields.io/badge/OS-macOS-lightgrey)
[![CI](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml/badge.svg)](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/lucuma13/lifsaver/graph/badge.svg?token=88HT6VMLHO)](https://codecov.io/gh/lucuma13/lifsaver)

<img src="docs/images/lifsaver_logo_name.svg" width="110" align="left" hspace="10"/>

`lifsaver` addresses a macOS bug on LIFS (Live Image File System) which prevents multiple cards from mounting when they have the same name (e.g. "Untitled"). It watches for cards that appear but never mount, and let's you force mount them with two clicks. Please note that whereas this utility has been fully tested, you should use it at your own risk.

<br clear="left"/>

<img src="docs/images/demo.gif" width="100%"/>

### 🚀 Installation

Download the latest [installer](https://github.com/lucuma13/lifsaver/releases/latest/download/lifsaver_installer_macos.pkg). Or simply:

```
brew install --cask lucuma13/dit/lifsaver
```

The installer is not notarized – macOS will warn on first open: right-click the .pkg → Open, or allow it under System Settings → Privacy & Security.

### 🐞 Reporting bugs

If the app misses a stalled card or fails to mount it, please send a diagnostic report: choose *Send Diagnostic Report* from the menu, optionally describe what happened, save the file, then click *Email Report* and send it to me (or open a [GitHub issue](https://github.com/lucuma13/lifsaver/issues/new)).


### ⚠️ Disclaimer

`lifsaver` deliberately circumvents standard macOS Disk Arbitration and LIFS (Live Image File System) protections to force-mount stalled volumes. The author assumes no liability for lost or corrupted data, or hardware failures of any kind.
