# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [1.1.0] - 2026-03-23

### Added

- In-app managed runtime setup so packaged `.app` and `.dmg` installs can provision the Android SDK, AVD, and `scrcpy` without cloning the repository first.
- Dedicated support-folder and persisted-log actions in the dashboard, menu bar utility, and activity-log window.
- Release automation for drag-to-Applications DMG builds with matching SHA-256 checksum files and bundled release notes.

### Changed

- Reworked the control area into a custom tabbed panel that separates runtime, background, inbox, and launcher settings more cleanly.
- Standardized managed runtime storage under `~/Library/Application Support/macOSdroid` across the app, bootstrap script, and documentation.
- Hardened launcher handling by validating Android package identifiers and sanitizing exported Finder launcher names more aggressively.
- Bundled the runtime bootstrap script and version metadata inside packaged app resources.

### Fixed

- Reduced repeated removable-volume access prompts by preferring managed SDK and AVD paths inside Application Support over legacy external or user-visible locations.
- Improved Homebrew detection so managed runtime setup works on both Apple Silicon and Intel Homebrew prefixes.
- Added bounded subprocess handling and setup logging around long-running tool invocations so runtime setup and health checks fail more transparently.
- Expanded early-boot APK install retry handling to cover transient Android package-manager null-pointer failures during cold starts.

### Compliance

- Added explicit attribution for the optional `scrcpy` dependency and refreshed dependency/install guidance for the managed runtime workflow.
- Ensured release artifacts carry `README.md`, `CHANGELOG.md`, `DEPENDENCIES.md`, `THIRD_PARTY_NOTICES.md`, `LICENSE`, and `VERSION`.

## [1.0.1] - 2026-03-14

### Added

- Filterable app-library search so large inboxes are easier to navigate from the dashboard.
- Generated release notes in `dist/macOSdroid-<version>-release-notes.md` as part of the release script.
- Bundled repository documentation inside packaged `.app` releases under `Contents/Resources/Documentation`.

### Changed

- Replaced personal support links with documentation and upstream license references in the UI and repository docs.
- Hardened packaging so the app bundle locates the built binary through SwiftPM instead of assuming a fixed output path.
- Added semantic-version validation to packaging and release scripts to keep release metadata consistent.

### Fixed

- Stopped creating or activating partial watch-folder paths while the user is still editing the inbox location.
- Made manual watch-folder changes apply cleanly before opening, rescanning, or revealing the inbox.
- Removed repository-owner references from tracked files to keep the open-source tree free of personal identifiers.

### Compliance

- Ensured distributed app bundles carry `README.md`, `CHANGELOG.md`, `DEPENDENCIES.md`, `THIRD_PARTY_NOTICES.md`, and `LICENSE`.
- Expanded dependency documentation to state explicitly that the Swift package has no third-party package dependencies.

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
