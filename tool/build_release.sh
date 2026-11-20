#!/usr/bin/env bash
# The one way to build a release: it stamps the app with the full source commit
# and the release tag (OPENSTRAP_SOURCE_SHA / OPENSTRAP_SOURCE_TAG, read by
# lib/data/official_export/mapper.dart) and refuses to start without both.
#
# Usage: tool/build_release.sh [apk|appbundle|ios] [flutter build args...]
#   OPENSTRAP_SOURCE_SHA  defaults to `git rev-parse HEAD`; must equal HEAD.
#   OPENSTRAP_SOURCE_TAG  defaults to the tag pointing at HEAD; required.
#   RELEASE_BUILD_DRY_RUN=1 prints the command line instead of running it.
#   FLUTTER               names the flutter executable (default: flutter).
# Bash 3.2 compatible: the iOS job runs it on macOS.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

kind=apk
case "${1:-}" in
  apk | appbundle | ios) kind=$1; shift ;;
esac

# The defines come from here only. A second copy on the command line could
# disagree with the checked values, and the later one would win.
for a in "$@"; do
  case "$a" in
    *OPENSTRAP_SOURCE_*)
      echo "release provenance: do not pass OPENSTRAP_SOURCE_* yourself; set the environment variables" >&2
      exit 2 ;;
  esac
done

head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || head=''
sha=${OPENSTRAP_SOURCE_SHA:-$head}
tag=${OPENSTRAP_SOURCE_TAG:-}
if [[ -z "$tag" ]]; then
  tag=$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null | head -n 1) || tag=''
fi

bash "$root/tool/check_release_provenance.sh" --sha "$sha" --tag "$tag" || exit 2
# An explicit sha is allowed (CI exports GITHUB_SHA) but must name this checkout.
if [[ -z "$head" || "$sha" != "$head" ]]; then
  echo "release provenance: OPENSTRAP_SOURCE_SHA ($sha) is not the checked-out HEAD (${head:-no git checkout})" >&2
  exit 2
fi
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
  echo "release provenance: warning: working tree has uncommitted changes; the sha does not describe them" >&2
fi

cmd=("${FLUTTER:-flutter}" build "$kind" --release "$@"
  "--dart-define=OPENSTRAP_SOURCE_SHA=$sha" "--dart-define=OPENSTRAP_SOURCE_TAG=$tag")
if [[ "${RELEASE_BUILD_DRY_RUN:-}" == 1 ]]; then
  printf '%s' "flutter build $kind --release"
  for a in "$@" "--dart-define=OPENSTRAP_SOURCE_SHA=$sha" "--dart-define=OPENSTRAP_SOURCE_TAG=$tag"; do printf ' %s' "$a"; done
  printf '\n'
  exit 0
fi
cd -- "$root"
exec "${cmd[@]}"
