#!/usr/bin/env python3 -I
"""Focused mutation checks for P1 (run through boat-run). Each mutation edits one
source file, runs the tests that must notice it, and REQUIRES a failing test.
Every file is restored in `finally`, even when a run is interrupted.
Usage: python3 -I run_mutations.py [unit|receiver|harness|layout]"""
import json, os, pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
L = 'lib/data/official_export/'
T = 'test/official_export/'
UNIT = {
 'profile: day_result policy flipped to kept': (L+'profile_tables.dart',
    "'day_result': TableProfile(\n      policy: TablePolicy.recomputed", "'day_result': TableProfile(\n      policy: TablePolicy.kept",
    [T+'profile_coverage_test.dart']),
 'profile: a table renamed (unclassified table)': (L+'profile_tables.dart',
    "'journal_metric': TableProfile(", "'journal_metric_x': TableProfile(", [T+'profile_coverage_test.dart']),
 'coverage: unclassified column ignored': (L+'profile.dart',
    "gaps.add(UnclassifiedColumn(shape.name, c));", "// mutated", [T+'profile_logic_test.dart']),
 'coverage: WITHOUT ROWID accepted': (L+'schema_catalog.dart',
    "if (withoutRowid || virtualTable) return null;", "if (virtualTable) return null;", [T+'profile_logic_test.dart']),
 'target DDL: imported column dropped': (L+'profile_target.dart',
    "imported INTEGER NOT NULL DEFAULT 0", "imported_gone INTEGER NOT NULL DEFAULT 0", [T+'target_layout_test.dart']),
 'cursor: fork-live cursor retained': (L+'prune_cursor.dart',
    "  final edge = calendar.midnightAtOrAfter(oldestExactSec);\n  return edge > forkCursorSec",
    "  final edge = forkCursorSec;\n  return edge > forkCursorSec", [T+'prune_cursor_test.dart']),
 'cursor: cap above the fork removed': (L+'prune_cursor.dart',
    "return edge > forkCursorSec\n      ? PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.cappedAtForkCursor)\n      : PrunedBeforeChoice(edge, PrunedBeforeReason.oldestExactMidnight);",
    "return PrunedBeforeChoice(edge, PrunedBeforeReason.oldestExactMidnight);", [T+'prune_cursor_test.dart']),
 'cursor: exact midnight rounds up a day': (L+'prune_cursor.dart',
    "return start >= sec ? start", "return start > sec ? start", [T+'prune_cursor_process_zone_test.dart']),
 'cursor: no fork cursor emits an input value': (L+'prune_cursor.dart',
    "return const PrunedBeforeChoice(null, PrunedBeforeReason.noForkCursor);",
    "return PrunedBeforeChoice(oldestExactSec, PrunedBeforeReason.noForkCursor);", [T+'prune_cursor_test.dart']),
 'cursor: no exact input drops the fork cursor': (L+'prune_cursor.dart',
    "return PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.noExactInput);",
    "return const PrunedBeforeChoice(null, PrunedBeforeReason.noExactInput);", [T+'prune_cursor_test.dart']),
 'profile: decoded_onehz.hr unclassified on real schema': (L+'profile_tables.dart',
    "'rec_ts', 'counter', 'hr', 'ax'", "'rec_ts', 'counter', 'ax'", [T+'profile_coverage_test.dart']),
 'fork catalog: kept hr type drifts without renaming': ('lib/data/db/schema.dart',
    "        hr INTEGER,\n        ax REAL,", "        hr TEXT,\n        ax REAL,", [T+'profile_coverage_test.dart']),
 'oldest exact: ts_ms used instead of rec_ts': (T+'candidate_stub.dart',
    "SELECT rec_ts FROM decoded_onehz WHERE rec_ts > 0 UNION ALL ",
    "SELECT ts_ms / 1000 AS rec_ts FROM decoded_onehz WHERE rec_ts > 0 UNION ALL ", [T+'payload_requirements_test.dart']),
 'oldest exact: invalid rec_ts included': (T+'candidate_stub.dart',
    "SELECT rec_ts FROM decoded_onehz WHERE rec_ts > 0 UNION ALL ",
    "SELECT rec_ts FROM decoded_onehz UNION ALL ", [T+'payload_requirements_test.dart']),
 'calendar: DST day treated as 24 h (flat +86400)': (L+'prune_cursor.dart',
    "return start >= sec ? start : localDayEndSec(label)!;", "return start >= sec ? start : start + 86400;", [T+'prune_cursor_process_zone_test.dart']),
 'payload: dropped-table rows not checked': (L+'payload_requirements.dart',
    "if (!carrying.contains(e.key) && !carrierNames.contains(e.key)) {", "if (false) {", [T+'payload_requirements_test.dart']),
 'payload: foreign cursor accepted': (L+'payload_requirements.dart',
    "if (n != 'decoded_pruned_before') {", "if (false) {", [T+'payload_requirements_test.dart']),
 'payload: carried cursor not compared': (L+'payload_requirements.dart',
    "if (payload.prunedBefore != expectedPrunedBefore) {", "if (false) {", [T+'payload_requirements_test.dart']),
}
RECEIVER = {
 'receiver: deleted status not checked': (T+'target/receiver_expectations.dart',
    "if (want && got != true) out.add('cut day $day is not labelled deleted');", "", ['receiver']),
 'receiver: g/mg conflation not checked': (T+'target/receiver_expectations.dart',
    "  if (unit != 'mg') {", "  if (false) {", ['receiver']),
}

LAYOUT = {
 'payload: view objects ignored': (L+'payload_requirements.dart',
    "for (final key in {...expectedObjects.keys, ...actualObjects.keys}) {",
    "for (final key in {...expectedObjects.keys, ...actualObjects.keys}) { if (key.$1 == 'view') continue;",
    [T+'payload_requirements_test.dart']),
}
HARNESS = {
 'receiver proof: pub-get lock comparison removed': (T+'harness/prepare_target.sh',
    "cmp pubspec.lock \"$OUT_DIR/tagged-pubspec.lock\" || { echo 'pub get changed the tagged receiver lock' >&2; exit 1; }",
    ": # mutated: accept a changed receiver lock", ['harness']),
}

def run(files):
    if files == ['harness']:
        cmd = ['bash', T+'harness/check_target_integrity.sh']
    elif files == ['receiver']:
        cmd = ['bash', T+'harness/run_receiver_scenarios.sh']
    else:
        cmd = ['flutter', 'test', '--concurrency=1', '-r', 'failures-only'] + files
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

table = {'unit': UNIT, 'receiver': RECEIVER, 'harness': HARNESS, 'layout': LAYOUT}[(sys.argv[1:] or ['unit'])[0]]
bad = []
results = []
evidence = ROOT / 'build/official_probe/mutations'
evidence.mkdir(parents=True, exist_ok=True)
for name, (path, old, new, files) in table.items():
    f = ROOT / path
    original = f.read_text()
    try:
        if old not in original:
            print(f'MUTATION NOT APPLICABLE: {name}', flush=True); bad.append(name); continue
        f.write_text(original.replace(old, new, 1))
        code, out = run(files)
        compile_error = 'Error:' in out and 'Expected:' not in out
        killed = code != 0 and not compile_error
        print(f"{'KILLED' if killed else 'SURVIVED'}: {name} (exit {code}{', compile error' if compile_error else ''})", flush=True)
        evidence.joinpath(re.sub(r'[^a-z0-9]+', '-', name.lower()) + '.log').write_text(
            json.dumps({'fork_head': os.environ.get('OFFICIAL_FORK_HEAD'),
                        'fork_status_porcelain': os.environ.get('OFFICIAL_FORK_STATUS')}) + '\n' + out)
        results.append(dict(name=name, path=path, exit=code, killed=killed, compile_error=compile_error))
        if not killed: bad.append(name)
    finally:
        f.write_text(original)
evidence.joinpath((sys.argv[1:] or ['unit'])[0] + '.json').write_text(json.dumps({
    'fork_head': os.environ.get('OFFICIAL_FORK_HEAD'),
    'fork_status_porcelain': os.environ.get('OFFICIAL_FORK_STATUS'),
    'mutations': results,
}, indent=2) + '\n')
sys.exit(1 if bad else 0)
