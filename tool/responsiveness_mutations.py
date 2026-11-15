#!/usr/bin/env python3
"""Focused red probes. Restores every source file, including on failures."""
from pathlib import Path
import subprocess
import sys

cases = [
    ('pending uses writer', 'lib/data/local_repository_impl.dart',
     "return LocalDb.readerRun((db) => ActivityStore(db).pending(), name: 'pending activities');",
     'return ActivityStore(await LocalDb.instance).pending();',
     'test/responsiveness_review_test.dart', 'all audited Review reads'),
    ('engine drops prepared revision', 'lib/compute/engine/day_compute.dart',
     '      sleepEditGeneration: day.sleepEditGeneration == null ? null : math.min(day.sleepEditGeneration!, history.sleepEditGeneration),\n',
     '', 'test/responsiveness_sleep_jobs_test.dart', 'the engine carries'),
    ('receipt omits dirty intent', 'lib/data/db/feature_store.dart',
     '      await SleepEditStore.enqueue(txn, dayId);',
     '', 'test/responsiveness_sleep_jobs_test.dart', 'assertion and dirty intent both roll back'),
    ('transaction omits queue timing', 'lib/data/db.dart',
     "        LoadTimings.shared.record(name, 'writer queue', queued.elapsedMicroseconds);",
     '', 'test/responsiveness_timings_test.dart', 'a real writer records'),
]
cases.append((
    'dependent days precede edited-night publication', 'lib/compute/derivation_engine.dart',
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
    if (onEdited != null && !await onEdited()) return done;""",
    'test/responsiveness_sleep_jobs_test.dart', 'the engine awaits edited-night publication'))
selected = set(sys.argv[1:])
failures = []
for index, (name, filename, old, new, test, match) in enumerate(cases):
    if selected and str(index) not in selected:
        continue
    path = Path(filename)
    original = path.read_text()
    assert old in original, (name, 'mutation site missing')
    try:
        path.write_text(original.replace(old, new, 1))
        with open(f'/tmp/responsiveness-mutation-{index}.log', 'w') as log:
            run = subprocess.run(['flutter', 'test', '--no-pub', '--concurrency=1', test,
                                  '--plain-name', match], stdout=log, stderr=subprocess.STDOUT, timeout=120)
        output = Path(f'/tmp/responsiveness-mutation-{index}.log').read_text()
        # A compile failure is not proof that the assertion catches the bug.
        caught = run.returncode != 0 and '[E]' in output and 'Compilation failed' not in output
        print(f'{name}: {"CAUGHT" if caught else "SURVIVED/INVALID"}', flush=True)
        if not caught:
            failures.append(name)
            print(output[-5000:], flush=True)
    finally:
        path.write_text(original)
assert not failures, failures
