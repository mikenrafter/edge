#!/usr/bin/env bash
# Owner-DB proof harness (Boat only). Upgrades a DISPOSABLE COPY of the owner's
# schema-89 database to the current fork schema, writes the naive and policy
# candidate files, then runs the unchanged v0.12.2 receiver
# (LocalDb.importFromDbFile) on each. Samples disk use every 2 s for the peak.
#   OWNER_ORIGINAL  default /home/user/owner-rh/original.db (never modified)
source "$(dirname "$0")/common.sh"
export OWNER_ORIGINAL="${OWNER_ORIGINAL:-/home/user/owner-rh/original.db}"
export OWNER_WORK="${OWNER_WORK:-/home/user/owner-rh/work}"
[ -f "$OWNER_ORIGINAL" ] || { echo "owner original missing: $OWNER_ORIGINAL" >&2; exit 2; }
mkdir -p "$OWNER_WORK"
bash "$(dirname "$0")/prepare_target.sh"
used() { df -B1 --output=used /home | tail -1 | tr -d ' '; }
base=$(used); peak=$base
( while true; do u=$(used); [ "$u" -gt "$(cat "$OUT_DIR/.peak" 2>/dev/null || echo 0)" ] && echo "$u" > "$OUT_DIR/.peak"; sleep 2; done ) &
sampler=$!
trap 'kill $sampler 2>/dev/null' EXIT
echo "$base" > "$OUT_DIR/.peak"
cd "$FORK_ROOT"
flutter gen-l10n >/dev/null
cp test/official_export/owner_upgrade_probe.dart test/official_export/owner_upgrade_test.dart
set +e
flutter test --concurrency=1 test/official_export/owner_upgrade_test.dart
up=$?
rm -f test/official_export/owner_upgrade_test.dart
rc=$up
if [ $up -eq 0 ]; then
  mkdir -p "$TARGET_DIR/test/official_export"
  rm -f "$TARGET_DIR"/test/official_export/*.dart
  cp test/official_export/target/owner_receiver_probe.dart "$TARGET_DIR/test/official_export/owner_receiver_test.dart"
  cd "$TARGET_DIR"
  OFFICIAL_PROBE_OUT="$OUT_DIR/target" flutter test --concurrency=1 test/official_export/owner_receiver_test.dart
  rc=$?
fi
peak=$(cat "$OUT_DIR/.peak")
echo "DISK base=$base peak=$peak delta_bytes=$((peak-base))" | tee "$OUT_DIR/owner-disk.txt"
echo "ORIGINAL sha256 now: $(sha256sum "$OWNER_ORIGINAL" | cut -d' ' -f1)"
exit $rc
