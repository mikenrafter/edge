// At the engine, override and skip-marker writers. A user override
// re-derive still writes a finalized (day, V) row (`run(force: true)` is what
// `_reanalyzeForOverride` calls; "Not sleep" on a finalized night whose raw is
// pruned still blanks it via `rederiveAfterSleepEdit`), a finalized day with no
// override is not rewritten, and `_markDaySkipped` never replaces a finalized
// row.
//
// Real LocalDb + real DerivationEngine, fixed local-time fixtures. Raw fixture as
// in sleep_override_blanks_night_test (two quiet nights + a lone data-edge
// reading on 2025-09-06). The override and "Not sleep" tests pin that the
// guard threads the override reason through every writer.
//
// OPEN (not pinned): `runDays(force: true)` from the Advanced "Re-analyze" and
// "Rebuild history with this priority" screens re-derives finalized days today.
// The spec lists only the override path; the parent decides whether those two
// explicit user actions pass the override reason.

// Each test runs whole derive passes; under full-suite load they need
// more than the default 30 s.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/frozen_day_result_fixtures.dart';

const _d1 = '2025-09-04';
const _d2 = '2025-09-05';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

late Database _db;

Future<void> _seedRaw() async {
  final b = _db.batch();
  var c = 0;
  void run(int from, int to, int Function(int) hr) {
    for (var ts = from; ts < to; ts++) {
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': c++,
        'hr': hr(ts),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  int night(int ts) => 52 + (ts % 7);
  run(_sec(2025, 9, 3, 22, 0), _sec(2025, 9, 4, 8, 0), night);
  run(_sec(2025, 9, 4, 22, 0), _sec(2025, 9, 5, 8, 0), night);
  run(_sec(2025, 9, 6, 12, 0), _sec(2025, 9, 6, 12, 1), (_) => 70);
  await b.commit(noResult: true);
}

/// A finalized sentinel row at [version]: a real-looking day (non-null scalars,
/// so the engine treats it as worth protecting) with a recognisable payload.
Future<void> _sentinel(
  String day, {
  int version = kAlgoVersion,
  bool finalized = true,
}) => seedRow(
  _db,
  day,
  version: version,
  finalized: finalized,
  tag: 'sentinel',
  series: {'rhr': 50.0, 'readiness': 70.0},
);

Future<void> _override(String day, int onset, int offset, String source) =>
    LocalDb.putSleepOverride(
      dayId: day,
      onsetTs: onset,
      offsetTs: offset,
      source: source,
    );

Future<Map<String, dynamic>> _scalars(String day) async {
  final r = (await rowOf(_db, day))!;
  final bundle = jsonDecode(r['payload_json'] as String) as Map<String, dynamic>;
  return (bundle['scalars'] as Map).cast<String, dynamic>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _db = await freshDb('openstrap_engine_override_test.db');
    await _seedRaw();
  });
  tearDownAll(dropDb);

  group('override re-derive (run(force: true))', () {
    test('a sleep-override day rewrites its finalized row; others stay frozen',
        () async {
      // d2: a real derived night the user then edits. d1: finalized, no override.
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'confirmed');
      await DerivationEngine().runDays(const Profile(), {_d2}, force: true);
      await _db.update('day_result',
          {'finalized': 1, 'computed_at': kSeedComputedAt},
          where: 'day_id = ?', whereArgs: [_d2]);
      expect((await _scalars(_d2))['tst_min'], 420);
      await _sentinel(_d1);
      final d1Before = (await rowOf(_db, _d1))!;

      // The user moves the window to 23:00 -> 07:00 (480 min) and the app
      // re-analyzes, exactly as `_reanalyzeForOverride` does.
      await _override(_d2, _sec(2025, 9, 4, 23, 0), _sec(2025, 9, 5, 7, 0),
          'confirmed');
      await DerivationEngine().run(const Profile(), force: true);

      expect((await _scalars(_d2))['tst_min'], 480,
          reason: 'the user\'s word beats the freeze');
      expect((await rowOf(_db, _d2))!['computed_at'], isNot(kSeedComputedAt));
      expect(await rowOf(_db, _d1), d1Before,
          reason: 'a finalized day without an override is not rewritten');
    });

    test('"Not sleep" on a finalized night with raw pruned still blanks it',
        () async {
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'confirmed');
      await DerivationEngine().runDays(const Profile(), {_d2}, force: true);
      await _db.update('day_result', {'finalized': 1},
          where: 'day_id = ?', whereArgs: [_d2]);
      expect((await _scalars(_d2))['tst_min'], 420);
      await _db.delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [_sec(2025, 9, 6, 0, 0)]);
      await _db.delete('sleep_session_candidates');

      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'rejected');
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d2);

      expect((await _scalars(_d2))['tst_min'], isNull);
      expect(await seriesOf(_db, _d2, 'tst_min'), isNull);
    });
  });

  group('skip marker', () {
    test('never replaces a finalized skip row at the same version', () async {
      await seedRow(
        _db,
        _d1,
        finalized: true,
        skipped: true,
        payload: jsonEncode({'skipped': true, 'reason': 'first_reason'}),
        series: const {},
      );
      final before = (await rowOf(_db, _d1))!;

      await DerivationEngine().debugMarkDaySkipped(
        _d1,
        _sec(2025, 9, 5, 0, 0),
        _sec(2025, 9, 6, 12, 0) + 30 * 86400,
        reason: 'second_reason',
      );

      expect(await rowOf(_db, _d1), before);
    });

    test('still writes a marker over a provisional skip row', () async {
      await seedRow(
        _db,
        _d1,
        finalized: false,
        skipped: true,
        payload: jsonEncode({'skipped': true, 'reason': 'first_reason'}),
        series: const {},
      );
      await DerivationEngine().debugMarkDaySkipped(
        _d1,
        _sec(2025, 9, 5, 0, 0),
        _sec(2025, 9, 6, 12, 0),
        reason: 'second_reason',
      );
      expect((await rowOf(_db, _d1))!['payload_json'],
          jsonEncode({'skipped': true, 'reason': 'second_reason'}));
    });
  });

  test('fixture is not vacuous: a confirmed window really stages a night', () async {
    await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
        'confirmed');
    await DerivationEngine().runDays(const Profile(), {_d2}, force: true);
    expect((await _scalars(_d2))['tst_min'], 420);
  });
}
