#!/usr/bin/env bash
# Check every outbound reference of the ECG screener page resolves.
#
# Reads lib/ecg/ecg_links.dart (the one constant kEcgLinks, one
# `EcgLink.doi('<state>', '<doi>')` or `EcgLink.layman('<state>', '<url>')` per
# line) and:
#   * for a DOI: GET https://api.crossref.org/works/<doi> must answer 200
#     (publishers answer a bare curl on doi.org with 403, so doi.org itself
#     is not the check; Crossref is the registry of record);
#   * for a layman page: curl -L must end in a 2xx.
# Prints one line per link and exits 1 if any failed. Needs network.
#
#   scripts/check_ecg_links.sh [path/to/ecg_links.dart]
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/lib/ecg/ecg_links.dart}"
ua='Mozilla/5.0 (compatible; openstrap-link-check)'
fail=0
total=0

[ -r "$src" ] || { echo "cannot read $src" >&2; exit 2; }

while IFS= read -r line; do
  kind="${line%%|*}"
  rest="${line#*|}"
  state="${rest%%|*}"
  ref="${rest#*|}"
  total=$((total + 1))
  case "$kind" in
    doi)
      code=$(curl -s -o /dev/null -m 25 -A "$ua" -w '%{http_code}' \
        "https://api.crossref.org/works/$ref")
      ;;
    layman)
      code=$(curl -s -o /dev/null -L -m 25 -A "$ua" -w '%{http_code}' "$ref")
      ;;
  esac
  case "$code" in
    2??) status=OK ;;
    *) status=FAIL; fail=$((fail + 1)) ;;
  esac
  printf '%-4s %s %-20s %-7s %s\n' "$status" "$code" "$state" "$kind" "$ref"
done < <(
  sed -nE "s/^[[:space:]]*EcgLink\.(doi|layman)\('([^']+)', *'([^']+)'\).*/\1|\2|\3/p" "$src"
)

if [ "$total" -eq 0 ]; then
  echo "no EcgLink entries found in $src" >&2
  exit 2
fi
echo "$((total - fail))/$total links resolve"
[ "$fail" -eq 0 ]
