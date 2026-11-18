#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
export TZ=UTC0 TZDIR=/usr/share/zoneinfo
bash "$(dirname "$0")/prepare_target.sh"
export CANDIDATES_DIR="$OUT_DIR/recompute-candidates"
mkdir -p "$CANDIDATES_DIR"
cd "$FORK_ROOT"
cp test/official_export/write_recompute_probe.dart test/official_export/write_recompute_test.dart
trap 'rm -f "$FORK_ROOT/test/official_export/write_recompute_test.dart"' EXIT
flutter test --concurrency=1 test/official_export/write_recompute_test.dart
mkdir -p "$TARGET_DIR/test/official_export"
cp test/official_export/target/p2_recompute_probe.dart "$TARGET_DIR/test/official_export/p2_recompute_test.dart"
cd "$TARGET_DIR"
OFFICIAL_PROBE_OUT="$OUT_DIR" flutter test --concurrency=1 test/official_export/p2_recompute_test.dart
