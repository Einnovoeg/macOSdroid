# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [1.0.0] - 2026-03-13

### Added

- Native SwiftUI macOS host for Android APK workflows with a dashboard and menu-bar control surface.
- Background Android runtime orchestration for a hidden Android Emulator instance.
- Watched inbox folder support for automatic APK discovery, installation, and optional launch.
- APK library management with import, drag-and-drop, install, reinstall, uninstall, and launch actions.
- Finder launcher export using the `macosdroid://` custom URL scheme.
- Launch-at-login support for the packaged `.app`.
- Runtime bootstrap and packaging scripts for local setup and Finder-ready distribution.
- Open-source project documentation including dependency, licensing, and third-party notice files.

### Changed

- Polished the dashboard and menu-bar UI with clearer runtime status, richer visual hierarchy, and support links.
- Expanded inline code comments and documentation across the runtime, toolchain, and settings layers.
- Standardized the packaged app identifier to `io.macosdroid.app`.
- Migrated settings loading to support legacy defaults domains without breaking existing installs.

### Fixed

- Resolved intermittent post-install launch failures by retrying app launch after successful package install.
- Ensured shell child processes do not hang waiting on inherited standard input.
- Improved runtime health tracking so emulator disconnects and exits are surfaced correctly.
- Corrected live inbox processing so APK drops reliably trigger install and launch behavior.

### Compliance

- Removed generated artifacts and machine-specific files from source control.
- Added repository-level third-party notices and dependency documentation.
- Applied the MIT License to the original project source while documenting the separate licenses for required external tools.

[1.0.0]: https://github.com/Einnovoeg/macOSdroid/releases/tag/v1.0.0
