#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NO_INSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install) NO_INSTALL=true; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

AVD_NAME="${EDGE_AVD_NAME:-edge_test}"
ABI="$( [[ "$(uname -m)" == aarch64 ]] && echo arm64-v8a || echo x86_64 )"
SYSTEM_IMAGE="${EDGE_SYSTEM_IMAGE:-system-images;android-35;default;$ABI}"
TIMEOUT="${EDGE_EMULATOR_START_TIMEOUT_SECONDS:-300}"
SETTLE="${EDGE_BOOT_SETTLE_SECONDS:-10}"
LAUNCH_PROBE="${EDGE_EMULATOR_LAUNCH_PROBE_SECONDS:-20}"
ORIGINAL_QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-}"

for cmd in adb emulator avdmanager sdkmanager flutter; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done
[[ -n "${ANDROID_SDK_ROOT:-}${ANDROID_HOME:-}" ]] || { echo "error: Android SDK is not configured; use nix develop" >&2; exit 1; }

serial() { adb devices | awk '/^emulator-[0-9]+\tdevice$/ { print $1; exit }'; }
running() { [[ -n "$(serial)" ]]; }

prepare_qt() {
  export QT_QPA_PLATFORM="$1"
  if [[ "$1" == xcb && -z "${DISPLAY:-}" && -n "${WAYLAND_DISPLAY:-}" ]]; then
    export DISPLAY=:0
  fi
}

launch_emulator() {
  local qt_platform="$1"
  shift
  prepare_qt "$qt_platform"
  echo "Launching with QT_QPA_PLATFORM=$qt_platform"
  echo "===== QT_QPA_PLATFORM=$qt_platform =====" >>/tmp/edge-emulator.log
  emulator "$@" >>/tmp/edge-emulator.log 2>&1 &
  local pid=$!
  disown

  local elapsed=0
  while (( elapsed < LAUNCH_PROBE )); do
    running && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 0
}

if ! sdkmanager --list_installed 2>/dev/null | grep -Fq "$SYSTEM_IMAGE"; then
  echo "Installing $SYSTEM_IMAGE"
  yes | sdkmanager "$SYSTEM_IMAGE"
fi
if ! avdmanager list avd -c | grep -Fxq "$AVD_NAME"; then
  echo "Creating AVD $AVD_NAME"
  echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d pixel_6
fi

started=false
if ! running; then
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || { echo "error: no graphical session (DISPLAY/WAYLAND_DISPLAY)" >&2; exit 1; }
  args=("@$AVD_NAME" -no-snapshot-load -no-boot-anim -gpu swiftshader_indirect)
  [[ -r /dev/kvm ]] && args+=(-accel on) || args+=(-accel off)
  launched=false
  if [[ -n "$ORIGINAL_QT_QPA_PLATFORM" ]]; then
    launch_emulator "$ORIGINAL_QT_QPA_PLATFORM" "${args[@]}" && launched=true
  fi
  if [[ "$launched" != true && "$ORIGINAL_QT_QPA_PLATFORM" != xcb ]]; then
    launch_emulator xcb "${args[@]}" && launched=true
  fi
  [[ "$launched" == true ]] || { echo "error: emulator exited during launch; see /tmp/edge-emulator.log" >&2; exit 1; }
  started=true
fi

device=""
elapsed=0
until device="$(serial)"; [[ -n "$device" ]]; do
  (( elapsed >= TIMEOUT )) && { echo "error: emulator did not register with adb; see /tmp/edge-emulator.log" >&2; exit 1; }
  sleep 2; ((elapsed += 2))
done
echo "Waiting for $device to boot..."
elapsed=0
until [[ "$(adb -s "$device" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do
  (( elapsed >= TIMEOUT )) && { echo "error: emulator boot timed out" >&2; exit 1; }
  sleep 2; ((elapsed += 2))
done
[[ "$started" == true ]] && sleep "$SETTLE"

if [[ "$NO_INSTALL" != true ]]; then
  flutter build apk --debug
  adb -s "$device" install -r build/app/outputs/flutter-apk/app-debug.apk
  echo "Installed Edge on $device"
else
  echo "Emulator ready: $device"
fi
