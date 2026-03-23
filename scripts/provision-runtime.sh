#!/bin/zsh

set -euo pipefail

APP_DOMAIN="${MACOSDROID_APP_DOMAIN:-io.macosdroid.app}"
APP_SUPPORT_ROOT="${MACOSDROID_APP_SUPPORT_ROOT:-$HOME/Library/Application Support/macOSdroid}"
SDK_ROOT="${MACOSDROID_SDK_ROOT:-$APP_SUPPORT_ROOT/Runtime/android-sdk}"
WATCH_FOLDER="${MACOSDROID_WATCH_FOLDER:-$APP_SUPPORT_ROOT/Inbox}"
ANDROID_USER_HOME="${MACOSDROID_ANDROID_USER_HOME:-$APP_SUPPORT_ROOT/AndroidUserHome}"
AVD_ROOT="${MACOSDROID_AVD_ROOT:-$ANDROID_USER_HOME/avd}"
LEGACY_SDK_ROOT="${MACOSDROID_LEGACY_SDK_ROOT:-$HOME/Library/Android/sdk}"
LEGACY_AVD_ROOT="${MACOSDROID_LEGACY_AVD_ROOT:-$HOME/.android/avd}"
AVD_NAME="${MACOSDROID_AVD_NAME:-macOSdroid-API35}"
SYSTEM_IMAGE="${MACOSDROID_SYSTEM_IMAGE:-system-images;android-35;google_apis;arm64-v8a}"
BUILD_TOOLS="${MACOSDROID_BUILD_TOOLS:-build-tools;35.0.0}"
PLATFORM="${MACOSDROID_PLATFORM:-platforms;android-35}"

brew_bin=""
for candidate in \
  "${HOMEBREW_PREFIX:-}/bin/brew" \
  "/opt/homebrew/bin/brew" \
  "/usr/local/bin/brew"
do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    brew_bin="$candidate"
    break
  fi
done

if [[ -z "$brew_bin" ]]; then
  echo "Homebrew is required but was not found in /opt/homebrew/bin/brew or /usr/local/bin/brew" >&2
  exit 1
fi

brew_prefix="$("$brew_bin" --prefix)"
cmdline_share="$brew_prefix/share/android-commandlinetools"
openjdk_home="$brew_prefix/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"

"$brew_bin" list --cask android-commandlinetools >/dev/null 2>&1 || "$brew_bin" install --cask android-commandlinetools
"$brew_bin" list openjdk@17 >/dev/null 2>&1 || "$brew_bin" install openjdk@17
# Install scrcpy alongside the SDK so packaged app launches can surface Android apps and
# attached-device views in separate macOS windows immediately after setup.
"$brew_bin" list scrcpy >/dev/null 2>&1 || "$brew_bin" install scrcpy

export JAVA_HOME="$openjdk_home"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_USER_HOME
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_AVD_HOME="$AVD_ROOT"

# Homebrew installs command-line tools in a shared prefix; copy them into the target SDK root so
# `sdkmanager`, `avdmanager`, and `apkanalyzer` all resolve consistently for the app.
mkdir -p "$SDK_ROOT/cmdline-tools" "$WATCH_FOLDER" "$ANDROID_USER_HOME" "$AVD_ROOT"
rsync -a "$cmdline_share/cmdline-tools/" "$SDK_ROOT/cmdline-tools/"

# When migrating from an older install, seed the managed SDK with any existing components so the
# app can move off external or user-visible locations without re-downloading everything.
if [[ -d "$LEGACY_SDK_ROOT" && "$LEGACY_SDK_ROOT" != "$SDK_ROOT" ]]; then
  for component in platform-tools emulator build-tools platforms system-images licenses; do
    if [[ -d "$LEGACY_SDK_ROOT/$component" ]]; then
      mkdir -p "$SDK_ROOT/$component"
      rsync -a --ignore-existing "$LEGACY_SDK_ROOT/$component/" "$SDK_ROOT/$component/"
    fi
  done
fi

# Seed the managed Android user home from any existing AVD so the emulator can start from the
# app-owned location without recreating the device image each time.
if [[ -d "$LEGACY_AVD_ROOT/$AVD_NAME.avd" && ! -d "$AVD_ROOT/$AVD_NAME.avd" ]]; then
  rsync -a "$LEGACY_AVD_ROOT/$AVD_NAME.avd/" "$AVD_ROOT/$AVD_NAME.avd/"
fi

if [[ -f "$LEGACY_AVD_ROOT/$AVD_NAME.ini" && ! -f "$AVD_ROOT/$AVD_NAME.ini" ]]; then
  cp "$LEGACY_AVD_ROOT/$AVD_NAME.ini" "$AVD_ROOT/$AVD_NAME.ini"
fi

real_sdk_root="$(cd "$SDK_ROOT" && pwd -P)"

if [[ -n "${MACOSDROID_AVD_PATH:-}" ]]; then
  avd_path="$MACOSDROID_AVD_PATH"
else
  avd_path="$AVD_ROOT/${AVD_NAME}.avd"
fi

mkdir -p "$(dirname "$avd_path")"

if [[ -f "$AVD_ROOT/$AVD_NAME.ini" ]]; then
  python3 - "$AVD_ROOT/$AVD_NAME.ini" "$avd_path" "$AVD_NAME" <<'PY'
import pathlib, sys
ini_path = pathlib.Path(sys.argv[1])
avd_path = pathlib.Path(sys.argv[2])
avd_name = sys.argv[3]
lines = []
seen_path = False
seen_rel = False
for raw_line in ini_path.read_text().splitlines():
    if raw_line.startswith("path="):
        lines.append(f"path={avd_path}")
        seen_path = True
    elif raw_line.startswith("path.rel="):
        lines.append(f"path.rel=avd/{avd_name}.avd")
        seen_rel = True
    else:
        lines.append(raw_line)
if not seen_path:
    lines.append(f"path={avd_path}")
if not seen_rel:
    lines.append(f"path.rel=avd/{avd_name}.avd")
ini_path.write_text("\n".join(lines) + "\n")
PY
fi

# `sdkmanager --licenses` exits as soon as the input stream closes, so feed it from a temporary
# file instead of piping `yes`, which would otherwise trip `pipefail` with SIGPIPE.
license_input="$(mktemp)"
trap 'rm -f "$license_input"' EXIT

for _ in {1..200}; do
  printf 'y\n'
done >"$license_input"

"$real_sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$real_sdk_root" --licenses <"$license_input" >/dev/null
"$real_sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$real_sdk_root" \
  "platform-tools" \
  "emulator" \
  "$BUILD_TOOLS" \
  "$PLATFORM" \
  "$SYSTEM_IMAGE"

if [[ ! -f "$avd_path/config.ini" ]]; then
  echo no | "$real_sdk_root/cmdline-tools/latest/bin/avdmanager" create avd -f \
    -n "$AVD_NAME" \
    -k "$SYSTEM_IMAGE" \
    -d pixel_7a \
    -p "$avd_path"
fi

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sdk_root_json="$(json_escape "$SDK_ROOT")"
avd_name_json="$(json_escape "$AVD_NAME")"
watch_folder_json="$(json_escape "$WATCH_FOLDER")"

settings_json=$(
  printf '{"sdkRootPath":"%s","avdName":"%s","watchFolderPath":"%s","autoLaunchAfterInstall":true,"autoStartRuntime":true,"menuBarOnly":true,"launchAtLogin":false,"showAndroidWindow":false,"preferSeparateAppWindows":true}' \
    "$sdk_root_json" \
    "$avd_name_json" \
    "$watch_folder_json"
)

settings_hex="$(printf '%s' "$settings_json" | xxd -p -c 1000)"
defaults write "$APP_DOMAIN" macOSdroid.settings -data "$settings_hex"

cat <<EOF
Provisioned macOSdroid runtime
  App support root: $APP_SUPPORT_ROOT
  SDK root: $SDK_ROOT
  Real SDK root: $real_sdk_root
  Android user home: $ANDROID_USER_HOME
  AVD root: $AVD_ROOT
  AVD name: $AVD_NAME
  AVD path: $avd_path
  Watch folder: $WATCH_FOLDER
  Defaults domain: $APP_DOMAIN
EOF

rm -f "$license_input"
trap - EXIT
