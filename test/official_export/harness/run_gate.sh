#!/usr/bin/env bash
# P1 gate: analyzer on the new code, the new unit tests, and test/guards.
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
  test/guards
