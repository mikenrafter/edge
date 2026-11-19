#!/usr/bin/env bash
# Final mapper/per-phase proof on the owner's disposable database, Boat only.
source "$(dirname "$0")/common.sh"
case "$FORK_ROOT" in /home/user/runs/*) ;; *) exit 2 ;; esac
export TZ='MST7MDT,M3.2.0,M11.1.0' TZDIR=/usr/share/zoneinfo
export OWNER_ROOT="$FORK_ROOT/build/owner-p2" OWNER_ORIGINAL="$FORK_ROOT/build/owner-p2/original.db"
export OWNER_WORK="$OWNER_ROOT/work" TMPDIR="$OWNER_ROOT/tmp" SQLITE_TMPDIR="$OWNER_ROOT/tmp"
mkdir -p "$OWNER_WORK" "$TMPDIR"
cleanup() { rm -f "$FORK_ROOT/test/official_export/owner_upgrade_test.dart"; rm -rf "$OWNER_ROOT" "$FORK_ROOT/build/owner-next"; }
trap cleanup EXIT
sha256sum "$OWNER_ORIGINAL"
echo "2b853726b715c70b3cbded2c317a2e7eab5015787f2ce8a8a55afd47716ee075  $OWNER_ORIGINAL" | sha256sum --check
cp test/official_export/owner_upgrade_probe.dart test/official_export/owner_upgrade_test.dart
flutter test --concurrency=1 -r expanded test/official_export/owner_upgrade_test.dart
python3 - "$OUT_DIR" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);data=json.loads((root/'owner-upgrade.json').read_text())
summary={k:v for k,v in data.items() if k.startswith('t:') or k in ('mapper_phase_ms','mapping_counts','source_value_conservation','original_unchanged','fork_head','fork_status_porcelain')}
(root/'owner-timing-final.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary),flush=True)
PY
