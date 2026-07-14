# lifsaver

![OS](https://img.shields.io/badge/OS-macOS%20%7C%20Windows-lightgrey)
[![Ruff](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/astral-sh/ruff/main/assets/badge/v2.json)](https://github.com/astral-sh/ruff)
[![ty](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/astral-sh/ty/main/assets/badge/v0.json)](https://github.com/astral-sh/ty)
[![CI](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml/badge.svg)](https://github.com/lucuma13/lifsaver/actions/workflows/ci.yml)

`lifsaver` addresses a macOS bug on LIFS (Live Image File System) which prevents multiple cards from mounting when they have the name "Untitled". Run it to force mount any card that is found. Please note that whereas this utility has been fully tested, you should use it at your own risk and only if you are confident using terminal commands.

### 🚀 Installation

1. Install the `uv` package manager with the [official installer](https://docs.astral.sh/uv/getting-started/installation/), or:
* macOS: `brew install uv`
* Windows: `winget install astral-sh.uv`
* Linux (Debian): `apt-get install uv`
<!--
* Linux (RHEL): `yum install uv`
* Linux (SUSE): `zypper install python-uv`
* Linux (Arch): `pacman -S muv`
-->

2. Install the toolkit:

```
uv tool install lifsaver
```

3. Test the installation (if the command is not recognised try `uv tool update-shell` and restart your terminal):

```
lifsaver --version
```

#### Alternative (macOS only)

Install with [Homebrew](https://brew.sh/): `brew install lucuma13/dit/mhl-suite`


### 📖 Usage

`lifsaver` first scans and reports how many stalled volumes it found (read-only and needs no privileges), then requires `sudo` to mount them. Run in any terminal:

```bash
lifsaver
```

### ⚠️ Disclaimer

`lifsaver` deliberately circumvents standard macOS Disk Arbitration and LIFS (Live Image File System) protections to force-mount stalled volumes. The author assumes no liability for lost or corrupted data, or hardware failures of any kind.
