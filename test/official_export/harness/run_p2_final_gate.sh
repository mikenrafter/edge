#!/usr/bin/env bash
# Serial final gate, on the owned Boat worktree. The base lib archive and frozen
# selection are supplied by the local caller; no owner files are used here.
source "$(dirname "$0")/common.sh"
export TZ=UTC0 TZDIR=/usr/share/zoneinfo
cd "$FORK_ROOT"
flutter gen-l10n >/dev/null
flutter analyze lib/data/official_export lib/data/attach_copy.dart lib/data/db.dart \
  lib/data/db/restore.dart lib/data/raw_archive_row.dart lib/util/raw_readers.dart \
  lib/util/worker_entries.dart test/official_export
set +e
python3 -I test/official_export/harness/run_p2_gate.py
graph=$?
set -e
# Fails on any incomplete batch, changed failure signature or unmatched case.
python3 -I test/official_export/harness/run_p2_baseline.py
echo "Selected graph exit $graph; exact baseline comparison passed"
python3 -I test/official_export/harness/run_p2_mutations.py
python3 -I test/official_export/harness/run_mutations.py unit
# Restored passing controls prove that neither mutation loop left source edits.
flutter test --concurrency=1 -r expanded test/official_export \
  test/sendable_officialMappingHeavy_test.dart test/step2/p21_write_seam_guard_test.dart \
  test/step2/p21_revision_identity_test.dart
bash test/official_export/harness/check_target_integrity.sh
bash test/official_export/harness/run_p2_recompute.sh
