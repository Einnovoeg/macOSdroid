# Third-Party Notices

This repository contains original `macOSdroid` source code only. It does not redistribute the Android SDK, Android Emulator, `adb`, OpenJDK, or any third-party APKs.

Those tools are installed separately by the user and remain under their original licenses. Credit and license references for the required third-party software are listed below.

## Runtime Prerequisites

| Software | Original authors / copyright holders | License | Notes |
| --- | --- | --- | --- |
| Android SDK Command-line Tools, Android Emulator, Android Platform Tools (`adb`) | Google LLC and Android Open Source Project contributors | Android Software Development Kit License Agreement | Required at runtime. Not bundled in this repository. Official terms: <https://developer.android.com/studio/terms> |
| OpenJDK 17 | Oracle and/or its affiliates, and other OpenJDK contributors | GNU General Public License, version 2, with the Classpath Exception | Required by Android command-line tools. Not bundled in this repository. Official license text: <https://openjdk.org/legal/gplv2+ce.html> |
| Homebrew | Homebrew contributors | BSD 2-Clause License | Optional helper used by the bootstrap script. Not bundled in this repository. Official project license: <https://github.com/Homebrew/brew/blob/master/LICENSE.txt> |

## Build And Platform Dependencies

| Software | Original authors / copyright holders | License | Notes |
| --- | --- | --- | --- |
| Swift toolchain | Apple Inc. and the Swift project authors | Apache License 2.0 with Runtime Library Exception | Required to build from source. Installed separately by the user through Xcode or the standalone toolchain. Project site: <https://www.swift.org/license/> |
| Apple macOS frameworks used by the app (`AppKit`, `SwiftUI`, `ServiceManagement`, `UniformTypeIdentifiers`) | Apple Inc. | Apple developer platform terms | System frameworks supplied by macOS and Xcode. Not redistributed in this repository. |

## Repository Policy

- No third-party source code is copied into this repository.
- No emulator system images are checked into source control.
- No third-party APK files are shipped with the project.
- Generated build products are excluded from source control via [`.gitignore`](.gitignore).
