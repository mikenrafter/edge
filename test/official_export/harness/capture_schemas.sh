#!/usr/bin/env bash
# Capture the repaired runtime schema of BOTH packages: the fork's current rung
# and the tagged v0.12.2 target. Output: build/official_probe/{fork,target}/*.json
source "$(dirname "$0")/common.sh"
bash "$(dirname "$0")/prepare_target.sh"
cd "$FORK_ROOT"
flutter gen-l10n
cp test/official_export/schema_probe.dart test/official_export/schema_probe_test.dart
OFFICIAL_PROBE_OUT="$OUT_DIR/fork" flutter test --concurrency=1 test/official_export/schema_probe_test.dart
rm -f test/official_export/schema_probe_test.dart
mkdir -p "$TARGET_DIR/test/official_export"
cp test/official_export/schema_probe.dart "$TARGET_DIR/test/official_export/schema_probe_test.dart"
cd "$TARGET_DIR"
OFFICIAL_PROBE_OUT="$OUT_DIR/target" flutter test --concurrency=1 test/official_export/schema_probe_test.dart
ls -la "$OUT_DIR/fork" "$OUT_DIR/target"
