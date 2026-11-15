#!/usr/bin/env python3
"""Hand-picked mutation probes for the responsiveness sleep-edit work.

Each case breaks one line, runs the named tests and expects an ASSERTION
failure (a compile failure proves nothing). Every source file is restored,
including on failure. Usage: tool/responsiveness_mutations.py [index ...]
"""
from pathlib import Path
import subprocess
import sys

FIX = 'test/responsiveness_sleep_fix_test.dart'
RETRY = 'test/responsiveness_sleep_retry_test.dart'
JOBS = 'test/responsiveness_sleep_jobs_test.dart'
CONTROLS = 'test/responsiveness_sleep_controls_test.dart'
TIMINGS = 'test/responsiveness_timings_test.dart'
REVIEW = 'test/responsiveness_review_test.dart'
REPO = 'lib/data/local_repository_impl.dart'

cases = [
    ('pending activities routed through the writer', REPO,
     "return LocalDb.readerRun((db) => ActivityStore(db).pending(), name: 'pending activities');",
     'return ActivityStore(await LocalDb.instance).pending();', [REVIEW]),
    ('engine drops the prepared edit generation', 'lib/compute/engine/day_compute.dart',
     '      sleepEditGeneration: fence,\n', '', [JOBS]),
    ('receipt omits the dirty job', 'lib/data/db/feature_store.dart',
     '      await SleepEditStore.enqueue(txn, dayId);', '', [JOBS]),
    ('writer queue timing omitted', 'lib/data/db.dart',
     "        LoadTimings.shared.record(name, 'writer queue', queued.elapsedMicroseconds);", '', [TIMINGS]),
    ('dependent days before edited-night publication', 'lib/compute/derivation_engine.dart',
     """    if (onEdited != null && !await onEdited()) return done;
    final later = {
      for (final d in (await LocalDb.decodedRecTsMaxByDay()).keys)
        if (d.compareTo(day) > 0) d,
    };
    if (later.isNotEmpty) done += await runDays(profile, later, force: true);""",
     """    final later = {
      for (final d in (await LocalDb.decodedRecTsMaxByDay()).keys)
        if (d.compareTo(day) > 0) d,
    };
    if (later.isNotEmpty) done += await runDays(profile, later, force: true);
    if (onEdited != null && !await onEdited()) return done;""", [JOBS]),
    # The reviewer's four survivors, and the new masking sites.
    ('withholding removed in _bundleAtForDate', REPO,
     "          await _withSleepEdit(date, await _withOlderValues(date, _dayMap(exact))),",
     "          await _withOlderValues(date, _dayMap(exact)),", [FIX]),
    ('withholding removed in _readBundle', REPO,
     "        ? await _withSleepEdit(date, await _withOlderValues(date, _dayMap(read)))",
     "        ? await _withOlderValues(date, _dayMap(read))", [FIX]),
    ('withholding removed in the latest-day fallback', REPO,
     "        final b = await _withSleepEdit(\n            chunk[j]['date'] as String, _dayMap(read));",
     "        final b = _dayMap(read);", [FIX]),
    ('isCurrent re-check removed', 'lib/state/app_state.dart',
     "      if (isCurrent != null && !await isCurrent()) return {};\n", '', [FIX]),
    ('scheduler hold dropped', 'lib/compute/derive_scheduler.dart',
     " || _manualHeld || _sleepEditHeld;", " || _manualHeld;", [FIX]),
    ('fence is global again', 'lib/data/db/derive_store.dart',
     "SleepEditStore.generationOn(txn, upTo: dayId)", "SleepEditStore.generationOn(txn)", [FIX]),
    ('no-outcome pass leaves the night unapplied', 'lib/state/app_state.dart',
     "      await SleepEditStore.markApplied(job);\n", '', [FIX]),
    ('refused run not requeued', 'lib/state/app_state.dart',
     "        throw const SleepEditRequeue('an earlier night was edited meanwhile');", "        // mutated", [FIX]),
    ('long wait fails the job', 'lib/state/app_state.dart',
     "      if (e.code == SyncFailure.calculationStuck) {", "      if (false) {", [RETRY]),
    ('failed jobs not retried in-process', 'lib/state/sleep_edit_runner.dart',
     "        _scheduleRetry();\n      } else if", "        // mutated\n      } else if", [RETRY]),
    ('requeue counted forever', 'lib/state/sleep_edit_runner.dart',
     "if (used >= maxRequeues) {", "if (false) {", [RETRY]),
    ('stale night shown in charts', 'lib/data/sleep_edit_store.dart',
     "        if (jobs.any((j) => j['day_id'] == date && j['applied_revision'] != j['revision'])) continue;\n", '', [FIX]),
    ('later days flagged hidden again', 'lib/data/sleep_edit_store.dart',
     "      if (r['day_id'] == day) {\n        own = r['phase'] as String;", "      if (true) {\n        own = r['phase'] as String;", [FIX, JOBS]),
    ('stale save failure dropped', 'lib/ui2/screens/sleep_detail.dart',
     "      if (failed != null) _surfaceStaleFailure(day, failed);\n      return;\n    }\n    if (_d?.day == day) _day = day;",
     "      return;\n    }\n    if (_d?.day == day) _day = day;", [CONTROLS]),
    ('failed card keeps pulsing', 'lib/ui2/screens/sleep_detail.dart',
     "    final running = n['recalculating'] == true && failed == null;", "    final running = n['recalculating'] == true || failed != null;", [CONTROLS]),
    ('timings on by default', 'lib/data/load_timings.dart',
     "Prefs.getBool(enabledKey, false)", "Prefs.getBool(enabledKey, true)", [TIMINGS]),
    ('background samples share the screen ring', 'lib/data/load_timings.dart',
     "    if (timing.route == _background) {", "    if (false) {", [TIMINGS]),
    ('every record writes at once', 'lib/data/load_timings.dart',
     "    _timer ??= Timer(saveInterval, () {", "    _timer ??= Timer(Duration.zero, () {", [TIMINGS]),
    ('activity review omits the job', 'lib/data/activity_store.dart',
     "      await SleepEditStore.enqueue(tx, main.day);", '', [FIX]),
]

selected = set(sys.argv[1:])
failures = []
out = Path('/tmp/responsiveness-mutations')
out.mkdir(exist_ok=True)
for index, (name, filename, old, new, tests) in enumerate(cases):
    if selected and str(index) not in selected:
        continue
    path = Path(filename)
    original = path.read_text()
    if old not in original:
        print(f'[{index}] {name}: SITE MISSING', flush=True)
        failures.append(name)
        continue
    log = out / f'{index}.log'
    try:
        path.write_text(original.replace(old, new, 1))
        with open(log, 'w') as handle:
            run = subprocess.run(['flutter', 'test', '--no-pub', '--concurrency=1', *tests],
                                 stdout=handle, stderr=subprocess.STDOUT, timeout=600)
        text = log.read_text()
        # A compile failure is not proof that an assertion catches the bug.
        caught = run.returncode != 0 and '[E]' in text and 'Compilation failed' not in text
        print(f'[{index}] {name}: {"CAUGHT" if caught else "SURVIVED/INVALID"}', flush=True)
        if not caught:
            failures.append(name)
            print(text[-3000:], flush=True)
    finally:
        path.write_text(original)
assert not failures, failures
