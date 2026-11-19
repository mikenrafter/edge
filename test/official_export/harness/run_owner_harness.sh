#!/usr/bin/env bash
# Owner-DB proof harness (Boat only). Upgrades a DISPOSABLE COPY of the owner's
# schema-89 database to the current fork schema, maps a verified policy file,
# then exercises unchanged v0.12.2 fresh/populated receivers. Samples disk use
# every 2 s. All owner-derived files stay in this run's build/owner-p2 directory.
source "$(dirname "$0")/common.sh"
export TZ='MST7MDT,M3.2.0,M11.1.0'
export TZDIR=/usr/share/zoneinfo
case "$FORK_ROOT" in /home/user/runs/*) ;; *) echo 'owner proof is Boat-only' >&2; exit 2 ;; esac
export OWNER_ROOT="$FORK_ROOT/build/owner-p2"
export OWNER_ORIGINAL="$OWNER_ROOT/original.db"
export OWNER_WORK="$OWNER_ROOT/work"
export TMPDIR="$OWNER_ROOT/tmp" SQLITE_TMPDIR="$OWNER_ROOT/tmp"
mkdir -p "$TMPDIR"
cleanup() {
  if [ -n "${sampler:-}" ]; then kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; fi
  rm -rf "$OWNER_ROOT"
}
trap cleanup EXIT
[ -f "$OWNER_ORIGINAL" ] || { echo "owner original missing: $OWNER_ORIGINAL" >&2; exit 2; }
echo "2b853726b715c70b3cbded2c317a2e7eab5015787f2ce8a8a55afd47716ee075  $OWNER_ORIGINAL" | sha256sum --check
mkdir -p "$OWNER_WORK"
bash "$(dirname "$0")/prepare_target.sh"
used() { df -B1 --output=used /home | tail -1 | tr -d ' '; }
base=$(used); peak=$base
( while true; do u=$(used); [ "$u" -gt "$(cat "$OUT_DIR/.peak" 2>/dev/null || echo 0)" ] && echo "$u" > "$OUT_DIR/.peak"; sleep 2; done ) &
sampler=$!
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
  cp test/official_export/target/p2_receiver_probe.dart "$TARGET_DIR/test/official_export/owner_receiver_test.dart"
  cd "$TARGET_DIR"
  OFFICIAL_PROBE_OUT="$OUT_DIR/target" flutter test --concurrency=1 test/official_export/owner_receiver_test.dart
  rc=$?
fi
peak=$(cat "$OUT_DIR/.peak")
echo "DISK base=$base peak=$peak delta_bytes=$((peak-base))" | tee "$OUT_DIR/owner-disk.txt"
echo "ORIGINAL sha256 now: $(sha256sum "$OWNER_ORIGINAL" | cut -d' ' -f1)"
exit $rc
