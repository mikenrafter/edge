#!/usr/bin/env bash
# The P1 unit gate: the profile/cursor/requirements tests plus test/guards.
# Run through boat-run. Reports the RESULT line of flutter test itself.
source "$(dirname "$0")/common.sh"
cd "$FORK_ROOT"
flutter gen-l10n >/dev/null
files="${GATE_FILES:-test/official_export/profile_logic_test.dart test/official_export/profile_coverage_test.dart test/official_export/target_layout_test.dart test/official_export/payload_requirements_test.dart test/official_export/prune_cursor_test.dart test/official_export/prune_cursor_process_zone_test.dart}"
flutter test --concurrency=1 -r expanded $files
