#!/usr/bin/env bash
set -u
export TZ=UTC
# Structural gate only. Two processes, each with one test worker, one sandbox.
python3 - <<'PY'
from pathlib import Path
names = '''responsiveness_review responsiveness_sleep_jobs responsiveness_sleep_controls responsiveness_timings
responsiveness_sleep_fix responsiveness_sleep_retry issue_report sleep_detail_disclaimer sleep_accordions
sleep_window_blank ui2_bug_batch_1022_sleep health_tabs calc_as_of_screens
structural_review_reads structural_review_measure structural_review_fix
sleep_override_rederive sleep_assertion_storage sleep_edit_window sleep_staged_read
sleep_recalculate_in_window_card ui2_sleep_detail sleep_detail_bundle
sync_sleep_operations db_read_connection activity_review activity_review_regression
app_state_derive_activity_review derive_recalc_state app_state_derive_scheduler
 derive_scheduler_retry derive_scheduler_manual_sync journal_fields
substrate_archive_db substrate_archive_import_txn'''.split()
files = [f'test/{n}_test.dart' for n in names]
files += [str(p) for p in Path('test/layout_shift').rglob('*test.dart')]
files += ['test/backup/settings_audit_guard_test.dart', 'test/backup/prefs_roundtrip_test.dart',
          'test/step2/p22_bundle_store_read_test.dart','test/step2/p22_bundle_store_fencing_test.dart',
          'test/step2/p23_publish_gate_test.dart','test/wake_journal/wake_persistence_test.dart',
          'test/wake_journal/wake_timeline_test.dart']
assert all(Path(p).exists() for p in files)
for i in range(2):
    Path(f'/tmp/responsiveness-files-{i}').write_text('\n'.join(files[i::2]))
print(f'Targeted gate: {len(files)} files, two shards')
PY
flutter test --no-pub --reporter expanded --concurrency=1 $(cat /tmp/responsiveness-files-0) > /tmp/responsiveness-gate-0.log 2>&1 & a=$!
flutter test --no-pub --reporter expanded --concurrency=1 $(cat /tmp/responsiveness-files-1) > /tmp/responsiveness-gate-1.log 2>&1 & b=$!
wait "$a"; x=$?
wait "$b"; y=$?
cat /tmp/responsiveness-gate-0.log /tmp/responsiveness-gate-1.log
printf 'Shard results: %s %s\n' "$x" "$y"
test "$x" = 0 && test "$y" = 0
