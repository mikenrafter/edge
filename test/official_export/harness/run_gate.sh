#!/usr/bin/env bash
# P1 focused gate. Also run the import-graph selection from the P1 fix brief.
source "$(dirname "$0")/common.sh"
cd "$FORK_ROOT"
flutter gen-l10n >/dev/null
flutter analyze lib/data/official_export test/official_export
flutter test --concurrency=1 -r failures-only \
  test/official_export/profile_logic_test.dart \
  test/official_export/profile_coverage_test.dart \
  test/official_export/target_layout_test.dart \
  test/official_export/payload_requirements_test.dart \
  test/official_export/prune_cursor_test.dart \
  test/official_export/prune_cursor_process_zone_test.dart \
  test/guards
