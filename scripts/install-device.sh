#!/usr/bin/env bash
# Build the debug app ("Edge Dev", id wtf.openstrap.openstrap_edge.dev) and
# install it on ONE adb device, then open it. The id differs from a release
# install on purpose, so this never replaces or conflicts with the real app.
#
# Device choice: EDGE_DEVICE or ANDROID_SERIAL if set; otherwise the only
# attached device, or the only physical one when emulators are also
# running. With none or several it stops and says what to do, rather than
# letting `adb` fail with "more than one device".
#
# --profile builds Flutter's profile mode instead: AOT-compiled like a release,
# so derivation and sync run at release speed. Flutter's profile build type
# starts from debug, so it keeps the ".dev" id, the "Edge Dev" label and the
# debug signing key, and installs over a debug install without losing data.
#
#   scripts/install-device.sh [--profile] [--no-build] [--no-launch]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_ID="wtf.openstrap.openstrap_edge.dev"
ACTIVITY="wtf.openstrap.openstrap_edge.MainActivity"
MODE=debug

BUILD=true
LAUNCH=true
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=false ;;
    --no-launch) LAUNCH=false ;;
    --profile) MODE=profile ;;
    *) echo "error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

APK="build/app/outputs/flutter-apk/app-$MODE.apk"

command -v adb >/dev/null || { echo "error: adb not found; run inside 'nix develop'" >&2; exit 1; }
adb start-server >/dev/null 2>&1 || true

want="${EDGE_DEVICE:-${ANDROID_SERIAL:-}}"
mapfile -t ready < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
mapfile -t blocked < <(adb devices | awk 'NR > 1 && ($2 == "unauthorized" || $2 == "offline") { print $1 " (" $2 ")" }')

if [[ -n "$want" ]]; then
  printf '%s\n' "${ready[@]}" | grep -Fxq "$want" || {
    echo "error: device '$want' is not attached and ready" >&2
    adb devices >&2
    exit 1
  }
  device="$want"
elif (( ${#ready[@]} == 1 )); then
  device="${ready[0]}"
elif mapfile -t phones < <(printf '%s\n' "${ready[@]}" | grep -v '^emulator-') &&
     (( ${#phones[@]} == 1 )); then
  # An emulator left running beside one real phone: the phone is the target.
  device="${phones[0]}"
elif (( ${#ready[@]} == 0 )); then
  echo "error: no adb device is ready." >&2
  (( ${#blocked[@]} )) && printf '  not usable: %s\n' "${blocked[@]}" >&2
  echo "  Plug in a phone and accept the USB debugging prompt, or run: make install-emulator" >&2
  exit 1
else
  echo "error: ${#ready[@]} devices are attached; pick one with EDGE_DEVICE=<serial> make install" >&2
  for d in "${ready[@]}"; do
    echo "  $d  $(adb -s "$d" shell getprop ro.product.model 2>/dev/null | tr -d '\r')" >&2
  done
  exit 1
fi
model="$(adb -s "$device" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
echo "Device: $device ${model:+($model)}"

if [[ "$BUILD" == true ]]; then
  flutter build apk "--$MODE"
fi
[[ -f "$APK" ]] || { echo "error: $APK not found; build first" >&2; exit 1; }

# -r replaces our own earlier dev install and keeps its data; -d allows the
# version code to go down between branches.
if ! out="$(adb -s "$device" install -r -d "$APK" 2>&1)"; then
  echo "$out" >&2
  if grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" <<<"$out"; then
    echo "" >&2
    echo "The installed $APP_ID was signed with a different key." >&2
    echo "Remove it (this deletes its data) and rerun:" >&2
    echo "  adb -s $device uninstall $APP_ID" >&2
  fi
  exit 1
fi
echo "Installed $APP_ID ($MODE) on $device"

if [[ "$LAUNCH" == true ]]; then
  adb -s "$device" shell am start -n "$APP_ID/$ACTIVITY" >/dev/null
  echo "Opened Edge Dev"
fi
