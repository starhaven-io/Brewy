# Brewy: A Homebrew GUI

<p align="center"><img src="assets/BrewyIcon.png" alt="Brewy icon" width="128"></p>

[![CI](https://github.com/starhaven-io/Brewy/actions/workflows/ci.yml/badge.svg)](https://github.com/starhaven-io/Brewy/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)

A native macOS app for managing [Homebrew](https://brew.sh) packages. Browse, search, install, and update formulae and casks — all without opening Terminal.

## Features

- Browse installed formulae and casks, including pinned packages and leaves
- Discover and search all Homebrew/core and Homebrew/cask packages
- View package details, dependencies, and a recursive dependency tree (what pulled a package in, and what it pulls in)
- Install, uninstall, upgrade, reinstall, pin, and unpin packages
- Upgrade all outdated packages at once, or select specific packages to upgrade
- Mac App Store integration via [`mas`](https://github.com/mas-cli/mas) (browse installed apps, check for updates)
- Manage Homebrew services (start, stop, restart)
- Organize packages into custom groups
- Action history with retry support for failed commands
- Manage taps (add/remove third-party repositories) with health monitoring for archived, moved, and missing taps
- Run `brew doctor`, remove orphaned packages, and clear the download cache with dry-run previews
- Menu bar extra showing outdated package count
- Configurable auto-refresh interval and brew path
- Light, dark, and system theme support
- Auto-updates via Sparkle

![Brewy demo](assets/BrewyDemo.gif)

## Requirements

- macOS 15.0 or later (Apple Silicon)
- [Homebrew](https://brew.sh) installed (defaults to `/opt/homebrew/bin/brew`, configurable in Settings)

## Installation

The best way to install Brewy is naturally with Homebrew. It's in [homebrew-cask](https://github.com/Homebrew/homebrew-cask):

```sh
brew install brewy
```

…or from the [starhaven-io tap](https://github.com/starhaven-io/homebrew-tap):

```sh
brew install starhaven-io/tap/brewy
```

You can also grab the latest release from the [GitHub releases page](https://github.com/starhaven-io/Brewy/releases).

## Building

1. Clone the repository
2. Open `Brewy.xcodeproj` in Xcode
3. Build and run (Cmd+R)

For local verification, install the optional tools listed in [CONTRIBUTING.md](CONTRIBUTING.md) and run:

```sh
just check
```

## Security model

Brewy is intentionally not sandboxed: it needs to execute the user's Homebrew installation and manage packages, casks, taps, and services on the local machine. CLI execution is centralized through `CommandRunner`, which invokes binaries with argument arrays rather than shell strings.

Destructive maintenance operations show Homebrew dry-run previews before they can run. Metadata links from package data, tap data, and release notes are restricted to `http` and `https` URLs before Brewy opens them externally.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, local checks, and commit conventions.

## Acknowledgements

Thanks to [@bevanjkay](https://github.com/bevanjkay) for the logo idea.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE) (`AGPL-3.0-only`).

Copyright (C) 2026 Patrick Linnane
