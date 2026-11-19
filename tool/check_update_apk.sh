#!/usr/bin/env bash
# Gate for a built APK, run on the build host before the APK is distributed.
# Dumps the packaged AndroidManifest.xml with aapt2 (or aapt), scans it and the
# Gradle merged manifest(s) for install capabilities, then runs the repository
# guard group (test/guards, EDGE_MERGED_MANIFEST) against the same files.
# Nothing is installed and no device is touched. Exit 0 only when every step
# passes; exit 2 on a missing or unusable input.
set -euo pipefail
usage() {
  echo 'Usage: check_update_apk.sh --apk FILE [--merged-manifest DIR] [--head SHA] [--variant NAME] [--output DIR]' >&2
  echo '  --merged-manifest defaults to build/app/intermediates/merged_manifest(s) under the repo;' >&2
  echo '  --head defaults to the checked-out commit, --variant to "release".' >&2
  echo '  AAPT2, AAPT, DART and FLUTTER name tools; otherwise PATH, then $ANDROID_HOME/build-tools.' >&2
  exit 2
}
apk='' merged='' head='' variant='' output=''
while (($#)); do
  (($# >= 2)) || usage
  case "$1" in
    --apk) apk=$2 ;;
    --merged-manifest) merged=$2 ;;
    --head) head=$2 ;;
    --variant) variant=$2 ;;
    --output) output=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$apk" ]] || usage
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
actual=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
head=${head:-$actual}
variant=${variant:-release}
[[ -s "$apk" ]] || { echo "APK does not exist or is empty: $apk" >&2; exit 2; }
if [[ -z "$merged" ]]; then
  # Gradle writes the merged manifests of each variant under one of these.
  for d in "$root"/build/app/intermediates/merged_manifests/* "$root"/build/app/intermediates/merged_manifest/*; do
    [[ -d "$d" && "$d" == *[Rr]elease* ]] && { merged=$d; break; }
  done
  [[ -n "$merged" ]] || {
    echo 'No merged manifest found: build the APK first or pass --merged-manifest DIR' >&2; exit 2;
  }
fi
[[ -d "$merged" ]] || { echo "Merged manifest directory does not exist: $merged" >&2; exit 2; }
[[ "$head" =~ ^[0-9a-fA-F]{40}$ && "$variant" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
[[ -n "$(find "$merged" -name AndroidManifest.xml -type f -size +0c -print -quit)" ]] || {
  echo "No nonempty merged AndroidManifest.xml under $merged" >&2; exit 2;
}
[[ "$actual" == "$head" ]] || { echo 'Source head does not match --head' >&2; exit 2; }
# aapt2 first (current SDKs ship only it), then classic aapt.
tool=''
for c in "${AAPT2:-}" "${AAPT:-}" "$(command -v aapt2 || true)" "$(command -v aapt || true)"; do
  [[ -n "$c" && -x "$c" ]] && { tool=$c; break; }
done
if [[ -z "$tool" ]]; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [[ -n "$sdk" ]] || continue
    c=$(find "$sdk/build-tools" -name aapt2 -type f 2>/dev/null | sort -V | tail -n 1)
    [[ -n "$c" ]] && { tool=$c; break; }
  done
fi
[[ -n "$tool" ]] || { echo 'aapt2 or aapt is required (set AAPT2/AAPT or ANDROID_HOME)' >&2; exit 2; }
dart=${DART:-dart}
command -v "$dart" >/dev/null || { echo 'dart is required' >&2; exit 2; }
command -v "${FLUTTER:-flutter}" >/dev/null || { echo 'flutter is required' >&2; exit 2; }
apk=$(realpath -- "$apk")
merged=$(realpath -- "$merged")
output=${output:-"$root/research/apk-hardening/$head/$variant"}
mkdir -p -- "$output"
output=$(realpath -- "$output")
# A failed rerun cannot leave an earlier success receipt looking current.
rm -f -- "$output/PASS"
if [[ "$(basename -- "$tool")" == aapt2* ]]; then
  "$tool" dump xmltree --file AndroidManifest.xml "$apk" > "$output/apk-manifest.txt"
else
  "$tool" dump xmltree "$apk" AndroidManifest.xml > "$output/apk-manifest.txt"
fi
grep -Eq '^[[:space:]]*E: manifest([[:space:]]|$)' "$output/apk-manifest.txt" || {
  echo 'aapt did not produce a manifest tree' >&2; exit 1;
}
grep -Eq '^[[:space:]]*E: application([[:space:]]|$)' "$output/apk-manifest.txt" || {
  echo 'aapt did not produce an application element' >&2; exit 1;
}
{
  printf 'head=%s\nvariant=%s\napk=%s\nmerged_manifest=%s\n' "$head" "$variant" "$apk" "$merged"
  sha256sum -- "$apk" "$output/apk-manifest.txt"
  find "$merged" -name AndroidManifest.xml -type f -exec sha256sum -- {} +
} > "$output/inputs.txt"
cd -- "$root"
# The scanner itself, on exactly the files the guard group reads. A banned
# component stops the gate here, with the offending file and line.
merged_files=()
while IFS= read -r f; do merged_files+=("$f"); done \
  < <(find "$merged" -name AndroidManifest.xml -type f | sort)
"$dart" run tool/scan_manifest.dart "$output/apk-manifest.txt" "${merged_files[@]}" \
  2>&1 | tee "$output/scan.log"
EDGE_MERGED_MANIFEST="$merged" EDGE_APK_MANIFEST_DUMP="$output/apk-manifest.txt" \
  "${FLUTTER:-flutter}" test --no-pub --reporter expanded test/guards \
  2>&1 | tee "$output/guards.log"
printf 'head=%s\nvariant=%s\ntool=%s\n' "$head" "$variant" "$tool" > "$output/PASS"
