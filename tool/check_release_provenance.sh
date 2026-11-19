#!/usr/bin/env bash
# Refuses a release build whose source provenance would export as "unknown".
# lib/data/official_export/mapper.dart reads OPENSTRAP_SOURCE_SHA and
# OPENSTRAP_SOURCE_TAG with defaultValue 'unknown'; this is the one place that
# decides whether a value is acceptable. Used by tool/build_release.sh.
#
# Usage: check_release_provenance.sh --sha FULL_SHA --tag TAG
set -euo pipefail
usage() { echo 'Usage: check_release_provenance.sh --sha FULL_SHA --tag TAG' >&2; exit 2; }
sha='' tag='' have_sha=0 have_tag=0
while (($#)); do
  (($# >= 2)) || usage
  case "$1" in
    --sha) sha=$2; have_sha=1 ;;
    --tag) tag=$2; have_tag=1 ;;
    *) usage ;;
  esac
  shift 2
done
((have_sha && have_tag)) || usage
trim() { local v=$1; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fail=0
bad() { echo "release provenance: $1" >&2; fail=1; }

s=$(trim "$sha")
if [[ -z "$s" || $(lower "$s") == unknown ]]; then
  bad "OPENSTRAP_SOURCE_SHA is missing or \"unknown\""
elif [[ ! "$s" =~ ^[0-9a-f]{40}$ ]]; then
  bad "OPENSTRAP_SOURCE_SHA must be the full 40-character lowercase commit sha, got \"$s\""
fi
if [[ "$sha" != "$s" ]]; then bad "OPENSTRAP_SOURCE_SHA has surrounding whitespace"; fi

t=$(trim "$tag")
if [[ -z "$t" || $(lower "$t") == unknown ]]; then
  bad "OPENSTRAP_SOURCE_TAG is missing or \"unknown\""
elif [[ ! "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]]; then
  # The value rides a --dart-define=KEY=VALUE argument: no spaces, commas or quotes.
  bad "OPENSTRAP_SOURCE_TAG may contain only letters, digits and . _ / + -, got \"$t\""
fi
if [[ "$tag" != "$t" ]]; then bad "OPENSTRAP_SOURCE_TAG has surrounding whitespace"; fi
exit "$fail"
