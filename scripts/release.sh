#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

release_notes_for_version() {
  awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { capture=1; next }
    capture && $0 ~ "^## \\[" { exit }
    capture { print }
  ' "$CHANGELOG_FILE"
}

VERSION="$(<"$VERSION_FILE")"
if ! is_semver "$VERSION"; then
  echo "VERSION must use semantic versioning (for example 1.1.0); got: $VERSION" >&2
  exit 1
fi

if [[ ! -f "$CHANGELOG_FILE" ]]; then
  echo "Missing CHANGELOG.md at $CHANGELOG_FILE" >&2
  exit 1
fi

BUILD_NUMBER="${MACOSDROID_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/macOSdroid.app"
ARCHIVE_PATH="$DIST_DIR/macOSdroid-$VERSION-macos.zip"
ARCHIVE_CHECKSUM_PATH="$DIST_DIR/macOSdroid-$VERSION-macos.zip.sha256"
DMG_PATH="$DIST_DIR/macOSdroid-$VERSION.dmg"
DMG_CHECKSUM_PATH="$DIST_DIR/macOSdroid-$VERSION.dmg.sha256"
RELEASE_NOTES_PATH="$DIST_DIR/macOSdroid-$VERSION-release-notes.md"

cd "$ROOT_DIR"

CHANGELOG_SECTION="$(release_notes_for_version)"
if [[ -z "${CHANGELOG_SECTION//[[:space:]]/}" ]]; then
  echo "CHANGELOG.md does not contain a section for version $VERSION" >&2
  exit 1
fi

# Produce a reproducible release bundle from the current tree, then create
# a distributable archive and checksum for GitHub Releases.
MACOSDROID_APP_VERSION="$VERSION" \
MACOSDROID_BUILD_NUMBER="$BUILD_NUMBER" \
  ./scripts/package-app.sh

MACOSDROID_APP_VERSION="$VERSION" \
MACOSDROID_BUILD_NUMBER="$BUILD_NUMBER" \
  ./scripts/package-dmg.sh

rm -f "$ARCHIVE_CHECKSUM_PATH" "$DMG_CHECKSUM_PATH" "$RELEASE_NOTES_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_CHECKSUM_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_CHECKSUM_PATH"

ARCHIVE_CHECKSUM_VALUE="$(cut -d' ' -f1 "$ARCHIVE_CHECKSUM_PATH")"
DMG_CHECKSUM_VALUE="$(cut -d' ' -f1 "$DMG_CHECKSUM_PATH")"
{
  echo "# macOSdroid $VERSION"
  echo
  echo "Build number: $BUILD_NUMBER"
  echo "ZIP archive: $(basename "$ARCHIVE_PATH")"
  echo "ZIP checksum (SHA-256): $ARCHIVE_CHECKSUM_VALUE"
  echo "DMG image: $(basename "$DMG_PATH")"
  echo "DMG checksum (SHA-256): $DMG_CHECKSUM_VALUE"
  echo
  echo "## Changelog"
  echo
  printf '%s\n' "$CHANGELOG_SECTION"
  echo
  echo "## Included documentation"
  echo
  echo "- README.md"
  echo "- CHANGELOG.md"
  echo "- DEPENDENCIES.md"
  echo "- THIRD_PARTY_NOTICES.md"
  echo "- LICENSE"
  echo "- VERSION"
} > "$RELEASE_NOTES_PATH"

echo "Release version: $VERSION"
echo "Build number: $BUILD_NUMBER"
echo "ZIP archive: $ARCHIVE_PATH"
echo "ZIP checksum: $ARCHIVE_CHECKSUM_PATH"
echo "DMG image: $DMG_PATH"
echo "DMG checksum: $DMG_CHECKSUM_PATH"
echo "Release notes: $RELEASE_NOTES_PATH"
