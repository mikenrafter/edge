#!/usr/bin/env bash
# Fork side writes candidate files; the unchanged v0.12.2 package imports them.
source "$(dirname "$0")/common.sh"
bash "$(dirname "$0")/prepare_target.sh"
export CANDIDATES_DIR="$OUT_DIR/candidates"
rm -rf "$CANDIDATES_DIR"
cd "$FORK_ROOT"
flutter gen-l10n >/dev/null
cp test/official_export/write_candidates.dart test/official_export/write_candidates_test.dart
flutter test --concurrency=1 test/official_export/write_candidates_test.dart
rm -f test/official_export/write_candidates_test.dart
mkdir -p "$TARGET_DIR/test/official_export"
rm -f "$TARGET_DIR"/test/official_export/*.dart
cp test/official_export/target/scenario.dart test/official_export/target/receiver_expectations.dart "$TARGET_DIR/test/official_export/"
cp test/official_export/target/receiver_scenarios_probe.dart "$TARGET_DIR/test/official_export/receiver_scenarios_test.dart"
cd "$TARGET_DIR"
OFFICIAL_PROBE_OUT="$OUT_DIR/target" flutter test --concurrency=1 test/official_export/receiver_scenarios_test.dart
