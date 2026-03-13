# macOSdroid

`macOSdroid` is a native SwiftUI macOS host for Android applications. It keeps the Android Emulator hidden in the background, watches an inbox folder for `.apk` files, installs them with `adb`, and can launch those apps from the dashboard, the menu bar, or Finder launchers.

## What It Does

- Starts an Android Virtual Device without opening the standard emulator window.
- Runs as a normal dashboard app or as a menu-bar-first background utility.
- Watches a configurable folder for `.apk` files and imports APKs directly from the UI.
- Installs changed APKs automatically with `adb install -r`.
- Tracks whether watched APKs are installed in the active Android runtime.
- Launches installed apps automatically when package metadata can be resolved.
- Exports Finder launchers as `.webloc` files backed by the `macosdroid://` URL scheme.
- Supports launch-at-login when running from the packaged `.app`.

## Requirements

- macOS 13 or newer
- Xcode 16 or newer, or a Swift 6.2 toolchain
- Android SDK components listed in [DEPENDENCIES.md](DEPENDENCIES.md)
- A JDK 17+ installation for Android command-line tools

The repository does not vendor the Android SDK, emulator, platform tools, or a JDK. Those must be installed separately by the user.

## Quick Start

1. Install the required host dependencies listed in [DEPENDENCIES.md](DEPENDENCIES.md).
2. Bootstrap the Android runtime:

```bash
chmod +x scripts/provision-runtime.sh
./scripts/provision-runtime.sh
```

3. Run the app in development:

```bash
swift run macOSdroid
```

4. Or package it as a Finder-launchable app:

```bash
chmod +x scripts/package-app.sh
./scripts/package-app.sh
open dist/macOSdroid.app
```

5. Import APKs with the `Import APKs` button, drag them onto the inbox card, or drop them into `~/Applications/macOSdroid Inbox`.

## Installation Details

### Bootstrap Script

[`scripts/provision-runtime.sh`](scripts/provision-runtime.sh) does the following:

- installs Homebrew-managed Android command-line tools if they are missing
- installs `openjdk@17` if it is missing
- provisions Android SDK packages required by the app
- creates an Android Virtual Device
- writes the app defaults domain so the packaged app starts with a working configuration

The default settings written by the script are:

- defaults domain: `io.macosdroid.app`
- SDK root: `~/Library/Android/sdk`
- watch folder: `~/Applications/macOSdroid Inbox`
- AVD name: `macOSdroid-API35`

### Packaged App

[`scripts/package-app.sh`](scripts/package-app.sh) builds a release binary, creates `dist/macOSdroid.app`, writes a minimal `Info.plist`, and ad-hoc signs the bundle so it can be opened from Finder.

## Project Files

- Source code: [`Sources/macOSdroid`](Sources/macOSdroid)
- Packaging script: [`scripts/package-app.sh`](scripts/package-app.sh)
- Runtime bootstrap script: [`scripts/provision-runtime.sh`](scripts/provision-runtime.sh)
- Dependency list: [`DEPENDENCIES.md`](DEPENDENCIES.md)
- Third-party notices: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
- License: [`LICENSE`](LICENSE)

## Compliance

This repository contains original project code only. It does not ship third-party SDK binaries, emulator images, or test APKs. Third-party tools required to run `macOSdroid` remain under their original licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and license links.

The project itself is licensed under the MIT License. See [LICENSE](LICENSE).

## Support

Support the project at [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg).
