// A manual sync derives only what changed.
//
// Every manual sync used to run a heavy derive over EVERY raw day that was not
// finalized: today (never finalized), plus any day stuck partial or skipped,
// recomputed on each tap even when the burst pulled nothing. `run(changedOnly:)`
// compares a per-day fingerprint of the decoded 1 Hz rows (newest rec_ts, row
// count, and the previous day's, since a day's night search reaches back into
// it) with the one recorded when the day was last derived. Equal => the
// derive would read the same bytes => provably redundant => skipped.
//
// Invariants these pin:
//   * zero new records => nothing runs, and every stored result is byte-for-byte
//     what it was (readiness included: a skipped derive cannot move it);
//   * new records on today only => today only;
//   * a partial day with no new data is not re-derived ...
//   * ... unless its raw is past the retention cutoff and only a complete
//     result lets the prune go on (invariant 9);
//   * a changed profile or a new algo version invalidates the fingerprint.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _counter = 1;

Future<void> _record(int ts) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'co$c',
      capturedAt: ts * 1000,
      recTs: ts,
    ),
    Sample(
      tsEpoch: ts,
      counter: c,
      hr: 62 + (c % 5),
      rrIntervalsMs: const [950],
      ax: 0,
      ay: 0,
      az: 1,
      spo2RedRaw: 1,
      spo2IrRaw: 1,
      skinTempRaw: 3000,
    ),
  );
}

/// A few minutes of 1 Hz data starting [startMin] minutes after local
/// midnight of [daysAgo] days back.
Future<void> _seedDay(int daysAgo, {int startMin = 60, int seconds = 120}) async {
  final n = DateTime.now();
  final base =
      DateTime(n.year, n.month, n.day - daysAgo, 0, startMin).millisecondsSinceEpoch ~/
      1000;
  for (var i = 0; i < seconds; i++) {
    await _record(base + i);
  }
}

String _day(int daysAgo) {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - daysAgo));
}

class _Pass {
  final List<String> days = [];
  final List<int> scopes = [];
}

Future<_Pass> _sync(DerivationEngine e, {Profile profile = const Profile()}) async {
  final out = _Pass();
  await e.run(
    profile,
    heavy: true,
    changedOnly: true,
    onScope: out.scopes.add,
    onDayDone: (day, i, n) => out.days.add(day),
  );
  return out;
}

Future<Map<String, String>> _stored() async => {
  for (final r in await LocalDb.recentDayResults(30))
    r['day_id'] as String:
        '${r['computed_at']}|${r['readiness']}|${r['partial']}|${r['payload_json']}',
};

void main() {
  group('selectChangedDays (pure)', () {
    test('keeps only days whose fingerprint differs from the recorded one', () {
      final todo = selectChangedDays(
        todoDays: const ['2026-10-01', '2026-10-02'],
        current: const {'2026-10-01': 'a', '2026-10-02': 'b2'},
        derived: const {'2026-10-01': 'a', '2026-10-02': 'b1'},
        prunePending: const {},
      );
      expect(todo, ['2026-10-02']);
    });

    test('a day never derived under this version always runs', () {
      final todo = selectChangedDays(
        todoDays: const ['2026-10-02'],
        current: const {'2026-10-02': 'b'},
        derived: const {},
        prunePending: const {},
      );
      expect(todo, ['2026-10-02']);
    });

    test('nothing changed => nothing to do', () {
      expect(
        selectChangedDays(
          todoDays: const ['2026-10-01', '2026-10-02'],
          current: const {'2026-10-01': 'a', '2026-10-02': 'b'},
          derived: const {'2026-10-01': 'a', '2026-10-02': 'b'},
          prunePending: const {},
        ),
        isEmpty,
      );
    });

    test('a day whose prune waits on a complete result is never skipped', () {
      final todo = selectChangedDays(
        todoDays: const ['2026-09-20', '2026-10-02'],
        current: const {'2026-09-20': 'a', '2026-10-02': 'b'},
        derived: const {'2026-09-20': 'a', '2026-10-02': 'b'},
        prunePending: const {'2026-09-20'},
      );
      expect(todo, ['2026-09-20']);
    });

    test('a day with no fingerprint (no raw) is not invented as changed', () {
      expect(
        selectChangedDays(
          todoDays: const ['2026-10-02'],
          current: const {},
          derived: const {},
          prunePending: const {},
        ),
        ['2026-10-02'],
        reason: 'unknown is not provably unchanged, so it runs',
      );
    });
  });

  group('prunePendingDays (pure)', () {
    test('only an incomplete day behind the retention cutoff is pending', () {
      final now = DateTime(2026, 10, 10, 12).millisecondsSinceEpoch ~/ 1000;
      final pending = DerivationEngine.prunePendingDays(
        rawDays: const ['2026-10-02', '2026-10-08', '2026-10-10'],
        derivedDayIds: const {'2026-10-10'},
        dataNowSec: now,
      );
      // 10-02 is older than rawRetentionDays and incomplete; 10-08 is still
      // inside the retention window; 10-10 is complete.
      expect(pending, {'2026-10-02'});
    });

    test('a complete day is never pending, however old', () {
      final now = DateTime(2026, 10, 10, 12).millisecondsSinceEpoch ~/ 1000;
      expect(
        DerivationEngine.prunePendingDays(
          rawDays: const ['2026-10-02'],
          derivedDayIds: const {'2026-10-02'},
          dataNowSec: now,
        ),
        isEmpty,
      );
    });
  });

  group('deriveFingerprint (pure)', () {
    test('changes with the day, the previous day, or the profile', () {
      final base = deriveFingerprint(profileSig: 'p', own: '9:10', previous: '5:3');
      expect(base, deriveFingerprint(profileSig: 'p', own: '9:10', previous: '5:3'));
      expect(base, isNot(deriveFingerprint(profileSig: 'p', own: '9:11', previous: '5:3')));
      expect(base, isNot(deriveFingerprint(profileSig: 'p', own: '9:10', previous: '5:4')));
      expect(base, isNot(deriveFingerprint(profileSig: 'q', own: '9:10', previous: '5:3')));
    });
  });

  group('run(changedOnly) against the real store', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_changed_only_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('first sync derives every pending day; the second derives nothing',
        () async {
      await _seedDay(2);
      await _seedDay(1);
      await _seedDay(0);
      final e = DerivationEngine();

      final first = await _sync(e);
      expect(first.days.toSet(), {_day(2), _day(1), _day(0)});
      expect(first.scopes, [3], reason: 'the scope is announced before any day ends');
      final before = await _stored();
      expect(before.keys, containsAll([_day(2), _day(1), _day(0)]));

      // The burst pulled zero new records.
      final second = await _sync(e);
      expect(second.days, isEmpty);
      expect(second.scopes, [0]);
      expect(e.snapshot()['todo_days'], 0);
      expect(e.snapshot()['unchanged_days'], 3);

      // Readiness (and everything else) is exactly what it was, including the
      // computed_at stamp: nothing was rewritten, so nothing could drift.
      expect(await _stored(), equals(before));
      final third = await _sync(e);
      expect(third.days, isEmpty);
      expect(await _stored(), equals(before));
    });

    test('new records on today only => today only', () async {
      final e = DerivationEngine();
      await _sync(e); // settle: everything recorded
      final before = await _stored();

      final n = DateTime.now();
      final t =
          DateTime(n.year, n.month, n.day, 0, 30).millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < 30; i++) {
        await _record(t + i);
      }

      final pass = await _sync(e);
      expect(pass.days, [_day(0)]);
      expect(pass.scopes, [1]);
      final after = await _stored();
      expect(after[_day(1)], before[_day(1)], reason: 'yesterday was not touched');
      expect(after[_day(2)], before[_day(2)], reason: 'nor the day before');
    });

    test('earlier-in-the-day records (max unchanged) still count as new',
        () async {
      final e = DerivationEngine();
      await _sync(e);
      // A gap fill: older than the day's newest record, so MAX(rec_ts) is the
      // same. The row count is not.
      final n = DateTime.now();
      final t =
          DateTime(n.year, n.month, n.day - 1, 0, 10).millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < 10; i++) {
        await _record(t + i);
      }
      final pass = await _sync(e);
      expect(pass.days.toSet(), containsAll([_day(1)]));
      expect(pass.days, isNot(contains(_day(2))),
          reason: 'two days back reads nothing from yesterday');
    });

    test('a partial day with no new data is not re-derived', () async {
      final e = DerivationEngine();
      await _sync(e);
      // Make yesterday a stuck partial: real row, second half failed.
      final row = (await LocalDb.dayResult(_day(1)))!;
      await LocalDb.putDayResult(
        dayId: _day(1),
        algoVersion: kAlgoVersion,
        payloadJson: row['payload_json'] as String,
        windowJson: row['window_json'] as String,
        partial: true,
      );
      final before = await _stored();

      final pass = await _sync(e);
      expect(pass.days, isEmpty);
      expect(await _stored(), equals(before));
    });

    test('a profile change invalidates the fingerprint', () async {
      final e = DerivationEngine();
      await _sync(e, profile: const Profile(ageYears: 30, sex: 'm'));
      final same = await _sync(e, profile: const Profile(ageYears: 30, sex: 'm'));
      expect(same.days, isEmpty);
      final changed = await _sync(e, profile: const Profile(ageYears: 41, sex: 'm'));
      expect(changed.days.toSet(), {_day(2), _day(1), _day(0)});
    });

    test('a different algo version never matches a recorded fingerprint',
        () async {
      await LocalDb.putDerivedFingerprint(_day(0), kAlgoVersion - 1, 'old');
      final fps = await LocalDb.derivedFingerprints(kAlgoVersion);
      expect(fps[_day(0)], isNot('old'));
    });

    test('an old incomplete day past retention is re-derived even if unchanged',
        () async {
      final e = DerivationEngine();
      await _sync(e); // settle everything else first

      // A day well behind the data edge whose result never completed, and whose
      // recorded fingerprint matches its raw exactly (nothing changed).
      final old = _day(9);
      await _seedDay(9);
      final fps = await LocalDb.decodedDayFingerprints([old, _day(10)]);
      await LocalDb.putDayResult(
        dayId: old,
        algoVersion: kAlgoVersion,
        payloadJson: '{"scalars":{}}',
        windowJson: '{}',
        partial: true,
      );
      await LocalDb.putDerivedFingerprint(
        old,
        kAlgoVersion,
        deriveFingerprint(
          profileSig: '{}',
          own: fps[old],
          previous: fps[_day(10)],
        )!,
      );

      final pass = await _sync(e);
      expect(pass.days, [old],
          reason: 'its raw is held by the prune until it completes, so a '
              'sync never skips it (invariant 9)');
      expect(pass.scopes, [1]);
    });
  });
}
