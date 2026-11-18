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

# boat-run syncs source without .git. Its caller supplies the local identity.
if git -C "$FORK_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  export OFFICIAL_FORK_HEAD="$(git -C "$FORK_ROOT" rev-parse HEAD)"
  export OFFICIAL_FORK_STATUS="$(git -C "$FORK_ROOT" status --porcelain)"
else
  : "${OFFICIAL_FORK_HEAD:?pass the fork HEAD from the local checkout}"
  : "${OFFICIAL_FORK_STATUS?pass git status --porcelain, including an empty value}"
fi
python3 - "$OUT_DIR/fork-identity.json" <<'IDENTITY'
import json, os, pathlib, sys
identity = {"fork_head": os.environ["OFFICIAL_FORK_HEAD"],
            "fork_status_porcelain": os.environ["OFFICIAL_FORK_STATUS"]}
text = json.dumps(identity, indent=2)
pathlib.Path(sys.argv[1]).write_text(text + "\n")
print(text, flush=True)
IDENTITY
