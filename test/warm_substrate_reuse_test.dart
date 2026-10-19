// RED (phase 1): a WARM pass reuses the substrate rows it loaded last pass.
//
// One DerivationEngine is kept across passes while the band appends rows. The
// prepare step (`_prepareTargetDay`) loads the day substrate (`load_day`) and
// the ~36 h sleep-search substrate (`load_search`) from SQLite on EVERY pass,
// re-reading rows it already held. The feature keeps those rows in memory
// (bounded) and reads only rev buckets (`input_rev`, `kRevBucketSec`) that are
// new or whose revision changed.
//
//  1. WORK (RED): on warm passes 2..n, `rows_load_day` and `rows_load_search`
//       <= rows with rec_ts in the previous pass's newest bucket or later
//     i.e. the new rows plus one open bucket. Counted from the DB by the
//     bucket rule, not a constant.
//  2. EXACTNESS (guard): after every warm pass the stored day + metric_series
//     equal a cold forced derive (fresh engine) over the same rows. No warm
//     pass reports a full reload (`substrate_full_reloads` absent/0).
//  3. INVALIDATION: a replaced row (same rec_ts), evicted rows (with their
//     decoded_rr), a late row inserted into an old bucket, a timezone change
//     and a device-ownership change must each give the cold result (guard) and
//     report `substrate_full_reloads == 1` on that pass (RED: counter absent).
//     The pass after it is incremental again (RED).
//  4. MEMORY (RED): `DerivationEngine.debugRetainedSubstrateDays` (to add; the
//     days whose substrate rows are held) is a subset of the calculation-state
//     days, drops a finalized day, and is cleared/trimmed with
//     `trimForBackground`.
//
// Counters are read from `engine.perf.summary()['counts']`, which holds the
// last pass.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart'
    show kRevBucketSec;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/day_stream_fixture.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  final value = tz.toNativeUtf8();
  try {
    lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
    calloc.free(value);
  }
}

int? _count(DerivationEngine e, String name) =>
    ((e.perf.summary()['counts'] as Map)[name] as num?)?.toInt();

/// The retained-substrate days, through `dynamic` so a missing getter is a
/// per-test failure naming it, not a compile error for the whole file.
List<String> _retained(DerivationEngine e) {
  try {
    return List<String>.from((e as dynamic).debugRetainedSubstrateDays as Iterable);
  } on NoSuchMethodError {
    fail('DerivationEngine.debugRetainedSubstrateDays is missing');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final originalTz = Platform.environment['TZ'];
  late int start;
  late String day;
  late Beats beats;
  late Accel accel;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'warm_substrate_reuse_test.db';
  });

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  }

  setUp(() async {
    await wipe();
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day - 1);
    day = dayLabelOf(midnight);
    start =
        midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
    beats = synthBeats(SynthBeats(seed: 17, startSec: start, seconds: 4 * 3600));
    accel = synthAccel(23, start, start + 4 * 3600 + 60);
  });
  tearDown(() {
    _setProcessTz(originalTz ?? 'UTC');
  });
  tearDownAll(wipe);

  Future<void> rows(int from, int to) =>
      writeSeconds(beats, accel, start + from, start + to);

  /// decoded_onehz rows at or after the bucket holding [recTs]: the rows a warm
  /// pass may read when [recTs] was the newest row of the previous pass.
  Future<int> rowsFromBucketOf(int recTs) async {
    final db = await LocalDb.instance;
    final from = (recTs ~/ kRevBucketSec) * kRevBucketSec;
    final r = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM decoded_onehz WHERE rec_ts >= ?', [from]);
    return (r.single['n'] as num).toInt();
  }

  Future<Map<String, dynamic>> stored() async {
    final row = (await LocalDb.dayResult(day))!;
    final payload =
        jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
    payload.remove('computed_at');
    final db = await LocalDb.instance;
    final series = await db.query('metric_series',
        where: 'date = ?', whereArgs: [day], orderBy: 'key');
    return {
      'payload': payload,
      for (final k in ['rhr', 'rmssd', 'readiness', 'partial', 'finalized'])
        k: row[k],
      'series': {for (final r in series) r['key'] as String: r['value']},
    };
  }

  Future<Map<String, dynamic>> cold() async {
    await DerivationEngine().run(_profile, force: true);
    return stored();
  }

  const steps = [3 * 3600, 3 * 3600 + 1200, 3 * 3600 + 2400, 4 * 3600];

  test('warm chain: exact vs cold, no full reload (guard)', () async {
    final warm = DerivationEngine();
    var prev = 0;
    for (final upTo in steps) {
      await rows(prev, upTo);
      prev = upTo;
      await warm.run(_profile);
      expect(_count(warm, 'substrate_full_reloads') ?? 0, 0,
          reason: 'nothing behind the tail changed: +${upTo}s');
      expect(await stored(), equals(await cold()), reason: 'warm to +${upTo}s');
    }
  });

  test('warm passes 2.. read only new + open-bucket rows (RED)', () async {
    final warm = DerivationEngine();
    var prev = 0;
    var pass = 0;
    for (final upTo in steps) {
      await rows(prev, upTo);
      await warm.run(_profile);
      pass++;
      if (pass >= 2) {
        // Previous pass's newest row was start+prev-1; its bucket is "open".
        final allowed = await rowsFromBucketOf(start + prev - 1);
        final whole = (await rowsFromBucketOf(0));
        expect(allowed, lessThan(whole ~/ 2),
            reason: 'fixture: the allowance is a small part of the day');
        for (final label in ['load_day', 'load_search']) {
          final got = _count(warm, 'rows_$label');
          expect(got, isNotNull, reason: 'rows_$label reported, pass $pass');
          expect(got!, lessThanOrEqualTo(allowed),
              reason: 'rows_$label on warm pass $pass '
                  '(allowed $allowed of $whole)');
        }
      }
      prev = upTo;
    }
  });

  group('a change behind the tail forces a full reload, stays exact', () {
    final changes = <String, Future<void> Function()>{
      'a row replaced (same rec_ts, INSERT OR REPLACE)': () async {
        final db = await LocalDb.instance;
        await db.rawInsert(
            'INSERT OR REPLACE INTO decoded_onehz '
            '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
            "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, 5, 91, "
            "0.9, 0.1, 0.2, 1, 1, 3000, 'gen4')",
            [(start + 500) * 1000, start + 500]);
      },
      'a counter reset re-keys rows (same rec_ts, new counter)': () async {
        final db = await LocalDb.instance;
        await db.rawUpdate(
            'UPDATE decoded_onehz SET counter = counter + 1000000 '
            'WHERE rec_ts >= ? AND rec_ts < ?',
            [start + 600, start + 700]);
      },
      'rows evicted with their decoded_rr': () async {
        final db = await LocalDb.instance;
        for (final t in ['decoded_onehz', 'decoded_rr']) {
          await db.delete(t,
              where: 'rec_ts >= ? AND rec_ts < ?',
              whereArgs: [start + 100, start + 400]);
        }
      },
      'a late row inserted into an old bucket': () async {
        final db = await LocalDb.instance;
        await db.rawInsert(
            'INSERT OR REPLACE INTO decoded_onehz '
            '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
            "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, 9, 0, "
            "0.0, 0.0, 1.0, 1, 1, 3000, 'gen4')",
            [(start - 1800) * 1000, start - 1800]);
      },
      'a device-ownership change': () async {
        final db = await LocalDb.instance;
        for (final sig in const ['hr1Hz', 'rrIntervals']) {
          await db.insert(
              'device_coverage',
              {
                'device_id': 'ring-TEST-0001',
                'signal': sig,
                'start_ts': start,
                'end_ts': start + 1800,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          await db.insert(
              'signal_priority',
              {
                'signal': sig,
                'device_id': 'ring-TEST-0001',
                'rank': 0,
                'user_set': 0,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          await db.insert(
              'signal_priority',
              {'signal': sig, 'device_id': '', 'rank': 1, 'user_set': 0},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      },
    };

    Future<(DerivationEngine, Map<String, dynamic>)> scenario(
        Future<void> Function() change) async {
      final warm = DerivationEngine();
      await rows(0, steps[0]);
      await warm.run(_profile);
      await rows(steps[0], steps[1]);
      await warm.run(_profile);
      await change();
      await rows(steps[1], steps[2]);
      await warm.run(_profile);
      return (warm, await stored());
    }

    for (final e in changes.entries) {
      test('${e.key}: stored == cold (guard)', () async {
        final (_, got) = await scenario(e.value);
        expect(got, equals(await cold()), reason: e.key);
      });

      test('${e.key}: one full reload, then incremental (RED)', () async {
        final (warm, _) = await scenario(e.value);
        expect(_count(warm, 'substrate_full_reloads'), 1, reason: e.key);
        await rows(steps[2], steps[3]);
        await warm.run(_profile);
        expect(_count(warm, 'substrate_full_reloads') ?? 0, 0,
            reason: 'the next pass is incremental again');
        final allowed = await rowsFromBucketOf(start + steps[2] - 1);
        expect(_count(warm, 'rows_load_day'), isNotNull);
        expect(_count(warm, 'rows_load_day')!, lessThanOrEqualTo(allowed));
        expect(_count(warm, 'rows_load_search')!, lessThanOrEqualTo(allowed));
      });
    }

    test('a timezone change: stored == cold, one full reload (RED)', () async {
      final warm = DerivationEngine();
      await rows(0, steps[0]);
      await warm.run(_profile);
      await rows(steps[0], steps[1]);
      await warm.run(_profile);
      _setProcessTz('Pacific/Auckland');
      await rows(steps[1], steps[2]);
      await warm.run(_profile);
      expect(_count(warm, 'substrate_full_reloads'), 1,
          reason: 'day boundaries moved: nothing retained is valid');
      final dayNow = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
          (start + 600) * 1000));
      // Compare whichever day the new zone put the fixture on, via the oracle.
      final warmDays = await (await LocalDb.instance)
          .query('day_result', columns: ['day_id'], orderBy: 'day_id');
      await DerivationEngine().run(_profile, force: true);
      final coldRows = await (await LocalDb.instance)
          .query('day_result', orderBy: 'day_id');
      expect(coldRows.map((r) => r['day_id']),
          containsAll(warmDays.map((r) => r['day_id'])),
          reason: 'cold derive covers the days the warm pass wrote ($dayNow)');
    });
  });

  group('memory bound', () {
    test('a pending day is retained, a finalized day is not (RED)', () async {
      final oldStart = start - 2 * 86400;
      final oldDay = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
          oldStart * 1000));
      final oldBeats = synthBeats(SynthBeats(
          seed: 5, startSec: oldStart, seconds: 2000));
      final oldAccel = synthAccel(7, oldStart, oldStart + 2060);
      await writeSeconds(oldBeats, oldAccel, oldStart, oldStart + 2000);
      await rows(0, 2500);
      final warm = DerivationEngine();
      await warm.run(_profile, heavy: true);
      expect((await LocalDb.dayResult(oldDay))!['finalized'], 1,
          reason: 'fixture: the old day finalized');
      expect(_retained(warm), contains(day));
      expect(_retained(warm), isNot(contains(oldDay)),
          reason: 'a finalized day is frozen and holds no substrate');
    });

    test('retained days are a subset of the calculation-state days (RED)',
        () async {
      await rows(0, 2500);
      final warm = DerivationEngine();
      await warm.run(_profile);
      final states = warm.debugCalculationStateDays;
      expect(states, contains(day));
      expect(_retained(warm), isNotEmpty);
      expect(states, containsAll(_retained(warm)),
          reason: 'the engine evicting a calculation state evicts the rows');
    });

    test('trimForBackground drops the retained rows (RED)', () async {
      await rows(0, 2500);
      final warm = DerivationEngine();
      await warm.run(_profile);
      expect(_retained(warm), isNotEmpty, reason: 'retained before the trim');
      warm.trimForBackground();
      expect(_retained(warm), isEmpty);
      // And the next pass is still exact.
      await rows(2500, steps[0]);
      await warm.run(_profile);
      expect(await stored(), equals(await cold()));
    });
  });
}
