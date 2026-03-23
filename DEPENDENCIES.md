# Dependencies

This project does not vendor its runtime dependencies. Install them separately before running `macOSdroid`.

## Swift Package Dependencies

- None. The Swift package builds against Apple-provided system frameworks only.

## Required Host Software

- macOS 13 or newer
- Xcode 16 or newer, or Swift 6.2
- JDK 17 or newer
- Android SDK root containing:
  - `platform-tools`
  - `emulator`
  - `cmdline-tools;latest`
  - `build-tools;35.0.0`
  - `platforms;android-35`
  - `system-images;android-35;google_apis;arm64-v8a`
- `scrcpy` for dedicated app windows and attached-device viewing

## Optional Host Software

- Homebrew
  - Required only if you want to use [`scripts/provision-runtime.sh`](scripts/provision-runtime.sh) exactly as written.

## Recommended Installation Paths

- App support root: `~/Library/Application Support/macOSdroid`
- Managed Android SDK: `~/Library/Application Support/macOSdroid/Runtime/android-sdk`
- Managed inbox: `~/Library/Application Support/macOSdroid/Inbox`
- Managed launchers: `~/Library/Application Support/macOSdroid/Launchers`

## Install With Homebrew

```bash
brew install openjdk@17
brew install --cask android-commandlinetools
brew install scrcpy
```

Then run:

```bash
./scripts/provision-runtime.sh
```

## Manual Android SDK Package Set

If you are provisioning the SDK yourself, install at least:

```text
platform-tools
emulator
cmdline-tools;latest
build-tools;35.0.0
platforms;android-35
system-images;android-35;google_apis;arm64-v8a
```

## Notes

- Packaged `.app` and `.dmg` installs can run the bundled `Prepare Managed Runtime` action instead of invoking the bootstrap script manually.
- `apkanalyzer` comes from the Android command-line tools package.
- `aapt` comes from Android build-tools and is used as a fallback for APK metadata extraction.
- The repository intentionally excludes bundled APKs and generated `.app` artifacts so source control remains license-clean and machine-agnostic.
