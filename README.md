# macOSdroid

`macOSdroid` is a native SwiftUI macOS host for Android applications. It keeps its managed runtime state under `~/Library/Application Support/macOSdroid`, watches an inbox folder for `.apk` files, installs them with `adb`, and can surface Android apps in dedicated `scrcpy` windows when `scrcpy` is available.

## What It Does

- Starts an Android Virtual Device without opening the standard emulator window.
- Runs as a normal dashboard app or as a menu-bar-first background utility.
- Watches a configurable folder for `.apk` files and imports APKs directly from the UI.
- Installs changed APKs automatically with `adb install -r`.
- Tracks whether watched APKs are installed in the active Android runtime.
- Opens Android apps inside dedicated `scrcpy` windows when available, with fallback to the emulator window when requested.
- Mirrors attached Android phones over ADB through the same `scrcpy` integration used for emulator-backed app windows.
- Exports Finder launchers as `.webloc` files backed by the `macosdroid://` URL scheme.
- Supports launch-at-login when running from the packaged `.app`.

## Requirements

- macOS 13 or newer
- Xcode 16 or newer, or a Swift 6.2 toolchain
- Android SDK components listed in [DEPENDENCIES.md](DEPENDENCIES.md)
- A JDK 17+ installation for Android command-line tools
- `scrcpy` for separate app windows and attached Android phone viewing

The repository does not vendor the Android SDK, emulator, platform tools, or a JDK. Those must be installed separately by the user.

## Quick Start

1. Install the required host dependencies listed in [DEPENDENCIES.md](DEPENDENCIES.md).
2. Bootstrap the Android runtime from the repository:

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

5. Or package a drag-to-Applications disk image:

```bash
chmod +x scripts/package-dmg.sh
./scripts/package-dmg.sh
open dist/macOSdroid-$(<VERSION).dmg
```

6. If you install the packaged `.app` or `.dmg`, open the app and click `Prepare Managed Runtime` in the `Runtime` tab. That runs the bundled setup script and installs the managed SDK, AVD, and `scrcpy` support into `~/Library/Application Support/macOSdroid`.
7. Import APKs with the `Import APKs` button, drag them onto the inbox card, or drop them into `~/Library/Application Support/macOSdroid/Inbox`.

## Releases

- Release version source: [`VERSION`](VERSION)
- Version history: [`CHANGELOG.md`](CHANGELOG.md)
- To build a versioned release archive locally:

```bash
chmod +x scripts/release.sh
./scripts/release.sh
```

That command produces:

- `dist/macOSdroid.app`
- `dist/macOSdroid-<version>-macos.zip`
- `dist/macOSdroid-<version>-macos.zip.sha256`
- `dist/macOSdroid-<version>.dmg`
- `dist/macOSdroid-<version>.dmg.sha256`
- `dist/macOSdroid-<version>-release-notes.md`

To build the drag-to-Applications disk image used for standalone distribution:

```bash
chmod +x scripts/package-dmg.sh
./scripts/package-dmg.sh
```

Before publishing a release, update `VERSION`, add the matching section to `CHANGELOG.md`, run `./scripts/release.sh`, then tag the commit as `v<version>` in your Git host of choice.

## Installation Details

### Bootstrap Script

[`scripts/provision-runtime.sh`](scripts/provision-runtime.sh) does the following:

- installs Homebrew-managed Android command-line tools if they are missing
- installs `openjdk@17` if it is missing
- installs `scrcpy` if it is missing
- provisions Android SDK packages required by the app
- creates an Android Virtual Device
- writes the app defaults domain so the packaged app starts with a working configuration

The default settings written by the script are:

- defaults domain: `io.macosdroid.app`
- app support root: `~/Library/Application Support/macOSdroid`
- SDK root: `~/Library/Application Support/macOSdroid/Runtime/android-sdk`
- Android user home: `~/Library/Application Support/macOSdroid/AndroidUserHome`
- watch folder: `~/Library/Application Support/macOSdroid/Inbox`
- AVD name: `macOSdroid-API35`

### Packaged App

[`scripts/package-app.sh`](scripts/package-app.sh) builds a release binary, creates `dist/macOSdroid.app`, copies repository documentation and license notices into `Contents/Resources/Documentation`, bundles `scripts/provision-runtime.sh` into `Contents/Resources/scripts`, writes a minimal `Info.plist`, and ad-hoc signs the bundle so it can be opened from Finder.

## Project Files

- Source code: [`Sources/macOSdroid`](Sources/macOSdroid)
- Packaging script: [`scripts/package-app.sh`](scripts/package-app.sh)
- DMG packaging script: [`scripts/package-dmg.sh`](scripts/package-dmg.sh)
- Release script: [`scripts/release.sh`](scripts/release.sh)
- Runtime bootstrap script: [`scripts/provision-runtime.sh`](scripts/provision-runtime.sh)
- Release version: [`VERSION`](VERSION)
- Dependency list: [`DEPENDENCIES.md`](DEPENDENCIES.md)
- Third-party notices: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
- License: [`LICENSE`](LICENSE)

## Compliance

This repository contains original project code only. It does not ship third-party SDK binaries, emulator images, or test APKs. Third-party tools required to run `macOSdroid` remain under their original licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and license links.

The project itself is licensed under the MIT License. See [LICENSE](LICENSE).

## Support
 
- Buy Me a Coffee: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

## Known Limitations and Future Work

`macOSdroid` is a work in progress. The following areas are known limitations or targets for future development:

- **Real Device Verification**: While ADB device mirroring is implemented, comprehensive verification with a wider range of real Android hardware is ongoing.
- **Bundled scrcpy**: Currently, `scrcpy` is an external dependency. We are evaluating whether to bundle it within the app resources for a completely offline installation experience.
- **Window Profiles**: Adding per-app window sizing and profile presets for `scrcpy` sessions to allow apps to open in their native aspect ratios.
- **GUI Polish**: Ongoing refinements to iconography, layout spacing, and copy for a more native macOS feel.

### Contribute!
If you encounter any bugs, have feature requests, or can help optimize the Android runtime orchestration, please open an issue or submit a pull request. Your help in making `macOSdroid` a robust tool for Android app management on macOS is greatly appreciated!

