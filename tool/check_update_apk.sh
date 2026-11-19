#!/usr/bin/env bash
# Run on the APK build host before distributing the first update-checker APK.
set -euo pipefail
usage() {
  echo 'Usage: check_update_apk.sh --apk FILE --merged-manifest DIR --head SHA --variant NAME [--output DIR]' >&2
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
[[ -n "$apk" && -n "$merged" && -n "$head" && -n "$variant" ]] || usage
[[ -s "$apk" ]] || { echo "APK does not exist or is empty: $apk" >&2; exit 2; }
[[ -d "$merged" ]] || { echo "Merged manifest directory does not exist: $merged" >&2; exit 2; }
[[ "$head" =~ ^[0-9a-fA-F]{40}$ && "$variant" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
[[ -n "$(find "$merged" -name AndroidManifest.xml -type f -size +0c -print -quit)" ]] || {
  echo "No nonempty merged AndroidManifest.xml under $merged" >&2; exit 2;
}
command -v "${AAPT:-aapt}" >/dev/null || { echo 'aapt is required' >&2; exit 2; }
command -v "${FLUTTER:-flutter}" >/dev/null || { echo 'flutter is required' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ "$(git -C "$root" rev-parse HEAD)" == "$head" ]] || {
  echo 'Source head does not match --head' >&2; exit 2;
}
apk=$(realpath -- "$apk")
merged=$(realpath -- "$merged")
output=${output:-"$root/research/apk-hardening/$head/$variant"}
mkdir -p -- "$output"
output=$(realpath -- "$output")
# A failed rerun cannot leave an earlier success receipt looking current.
rm -f -- "$output/PASS"
"${AAPT:-aapt}" dump xmltree "$apk" AndroidManifest.xml > "$output/apk-manifest.txt"
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
EDGE_MERGED_MANIFEST="$merged" EDGE_APK_MANIFEST_DUMP="$output/apk-manifest.txt" \
  "${FLUTTER:-flutter}" test --no-pub --reporter expanded test/guards \
  2>&1 | tee "$output/guards.log"
printf 'head=%s\nvariant=%s\n' "$head" "$variant" > "$output/PASS"
