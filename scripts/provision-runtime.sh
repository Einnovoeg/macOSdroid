#!/bin/zsh

set -euo pipefail

APP_DOMAIN="${MACOSDROID_APP_DOMAIN:-io.macosdroid.app}"
SDK_ROOT="${MACOSDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
WATCH_FOLDER="${MACOSDROID_WATCH_FOLDER:-$HOME/Applications/macOSdroid Inbox}"
AVD_NAME="${MACOSDROID_AVD_NAME:-macOSdroid-API35}"
SYSTEM_IMAGE="${MACOSDROID_SYSTEM_IMAGE:-system-images;android-35;google_apis;arm64-v8a}"
BUILD_TOOLS="${MACOSDROID_BUILD_TOOLS:-build-tools;35.0.0}"
PLATFORM="${MACOSDROID_PLATFORM:-platforms;android-35}"

brew_bin="${HOMEBREW_PREFIX:-/opt/homebrew}/bin/brew"
cmdline_share="${HOMEBREW_PREFIX:-/opt/homebrew}/share/android-commandlinetools"
openjdk_home="${HOMEBREW_PREFIX:-/opt/homebrew}/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"

if [[ ! -x "$brew_bin" ]]; then
  echo "Homebrew is required at $brew_bin" >&2
  exit 1
fi

"$brew_bin" list --cask android-commandlinetools >/dev/null 2>&1 || "$brew_bin" install --cask android-commandlinetools
"$brew_bin" list openjdk@17 >/dev/null 2>&1 || "$brew_bin" install openjdk@17

export JAVA_HOME="$openjdk_home"
export PATH="$JAVA_HOME/bin:$PATH"

# Homebrew installs command-line tools in a shared prefix; copy them into the target SDK root so
# `sdkmanager`, `avdmanager`, and `apkanalyzer` all resolve consistently for the app.
mkdir -p "$SDK_ROOT/cmdline-tools" "$WATCH_FOLDER"
rsync -a "$cmdline_share/cmdline-tools/" "$SDK_ROOT/cmdline-tools/"

real_sdk_root="$(cd "$SDK_ROOT" && pwd -P)"

home_avail_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
if [[ -n "${MACOSDROID_AVD_PATH:-}" ]]; then
  avd_path="$MACOSDROID_AVD_PATH"
elif [[ "${home_avail_gb:-0}" -lt 12 ]]; then
  avd_path="$(dirname "$real_sdk_root")/avd/${AVD_NAME}.avd"
else
  avd_path="$HOME/.android/avd/${AVD_NAME}.avd"
fi

mkdir -p "$(dirname "$avd_path")"

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
  printf '{"sdkRootPath":"%s","avdName":"%s","watchFolderPath":"%s","autoLaunchAfterInstall":true,"autoStartRuntime":true,"menuBarOnly":true,"launchAtLogin":false}' \
    "$sdk_root_json" \
    "$avd_name_json" \
    "$watch_folder_json"
)

settings_hex="$(printf '%s' "$settings_json" | xxd -p -c 1000)"
defaults write "$APP_DOMAIN" macOSdroid.settings -data "$settings_hex"

cat <<EOF
Provisioned macOSdroid runtime
  SDK root: $SDK_ROOT
  Real SDK root: $real_sdk_root
  AVD name: $AVD_NAME
  AVD path: $avd_path
  Watch folder: $WATCH_FOLDER
  Defaults domain: $APP_DOMAIN
EOF

rm -f "$license_input"
trap - EXIT
