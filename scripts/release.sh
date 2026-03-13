#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

VERSION="$(<"$VERSION_FILE")"
BUILD_NUMBER="${MACOSDROID_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/macOSdroid.app"
ARCHIVE_PATH="$DIST_DIR/macOSdroid-$VERSION-macos.zip"
CHECKSUM_PATH="$DIST_DIR/macOSdroid-$VERSION-macos.zip.sha256"

cd "$ROOT_DIR"

# Produce a reproducible release bundle from the current tree, then create
# a distributable archive and checksum for GitHub Releases.
MACOSDROID_APP_VERSION="$VERSION" \
MACOSDROID_BUILD_NUMBER="$BUILD_NUMBER" \
  ./scripts/package-app.sh

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "Release version: $VERSION"
echo "Build number: $BUILD_NUMBER"
echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
