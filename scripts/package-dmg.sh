#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

VERSION="${MACOSDROID_APP_VERSION:-$(<"$VERSION_FILE")}"
if ! is_semver "$VERSION"; then
  echo "VERSION must use semantic versioning (for example 1.1.0); got: $VERSION" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/macOSdroid.app"
DMG_STAGE_DIR="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/macOSdroid-$VERSION.dmg"

cd "$ROOT_DIR"
if [[ -n "${MACOSDROID_BUILD_NUMBER:-}" ]]; then
  MACOSDROID_APP_VERSION="$VERSION" \
  MACOSDROID_BUILD_NUMBER="$MACOSDROID_BUILD_NUMBER" \
    ./scripts/package-app.sh
else
  MACOSDROID_APP_VERSION="$VERSION" ./scripts/package-app.sh
fi

rm -rf "$DMG_STAGE_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_PATH" "$DMG_STAGE_DIR/macOSdroid.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

# Create a simple drag-to-Applications disk image. Notarization and custom Finder layout can be
# layered on top later without changing the app bundle build itself.
hdiutil create \
  -volname "macOSdroid" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGE_DIR"

echo "Created $DMG_PATH"
