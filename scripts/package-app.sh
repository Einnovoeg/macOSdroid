#!/bin/zsh

set -euo pipefail

APP_IDENTIFIER="io.macosdroid.app"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Keep the packaged app version aligned with the repository release version unless
# a caller explicitly overrides it.
APP_VERSION="${MACOSDROID_APP_VERSION:-$(<"$VERSION_FILE")}"
if ! is_semver "$APP_VERSION"; then
  echo "APP_VERSION must use semantic versioning (for example 1.0.1); got: $APP_VERSION" >&2
  exit 1
fi

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DEFAULT_BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
else
  DEFAULT_BUILD_NUMBER="1"
fi
APP_BUILD_NUMBER="${MACOSDROID_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
APP_DIR="$ROOT_DIR/dist/macOSdroid.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DOCS_DIR="$RESOURCES_DIR/Documentation"
SCRIPTS_DIR="$RESOURCES_DIR/scripts"

cd "$ROOT_DIR"
swift build -c release --product macOSdroid
BUILD_DIR="$(swift build -c release --show-bin-path)"
BINARY_PATH="$BUILD_DIR/macOSdroid"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Built binary not found at $BINARY_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$DOCS_DIR" "$SCRIPTS_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/macOSdroid"
cp "$ROOT_DIR/README.md" "$DOCS_DIR/README.md"
cp "$ROOT_DIR/CHANGELOG.md" "$DOCS_DIR/CHANGELOG.md"
cp "$ROOT_DIR/DEPENDENCIES.md" "$DOCS_DIR/DEPENDENCIES.md"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$DOCS_DIR/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/LICENSE" "$DOCS_DIR/LICENSE"
cp "$ROOT_DIR/VERSION" "$DOCS_DIR/VERSION"
cp "$ROOT_DIR/scripts/provision-runtime.sh" "$SCRIPTS_DIR/provision-runtime.sh"
chmod +x "$SCRIPTS_DIR/provision-runtime.sh"

# Generate the minimal bundle metadata required for Finder launches, custom URL routing,
# and launch-at-login registration.
plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string macOSdroid" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $APP_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string macOSdroid" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Copyright © 2026 macOSdroid contributors" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $APP_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string macosdroid" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"

echo "Created $APP_DIR (version $APP_VERSION, build $APP_BUILD_NUMBER)"
