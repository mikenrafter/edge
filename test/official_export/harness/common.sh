# Sourced by the harness scripts. Run them only through boat-run (a Boat sandbox):
# the owner's database and the tagged package never live on this host.
# NO INSTALLS: these scripts only compile and run tests against the tagged source.
set -eo pipefail
export TARGET_TAG=v0.12.2
export TARGET_SHA=cd64eaa89948409ccffbea19ee48d7bd22dcb808
export TARGET_DIR=/home/user/official-v0.12.2
export TARGET_SRC=/home/user/official-v0.12.2-src.git
export FORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export OUT_DIR="$FORK_ROOT/build/official_probe"
mkdir -p "$OUT_DIR"
