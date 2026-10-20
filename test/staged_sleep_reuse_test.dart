// Staged-sleep reuse (RED). After a restore the heavy pass stages each night
// (`stage_candidate`, `stageSleepCandidateHeavy` on a worker) and the baseline
// rescan that follows stages the SAME nights again from scratch, although only
// baseline-dependent scalars (readiness, stress, illness) move in a rescan.
// Plan: a bounded in-memory cache of the staged candidate, filled by the heavy
// pass and reused by `rescanRecent` while the key matches:
//
//     (day, the day's input fingerprint / input revision, kAlgoVersion)
//
// HOW STAGINGS ARE COUNTED. No lib counter is needed: every staging is a
// `Dispatcher.cancellable` dispatch labelled `sleep-staging <dayId>`
// (`WorkerAudit.onDispatch`), one per worker run, so the test reads WHICH days
// were staged and how often.
//
// SEAMS (stubs on `DerivationEngine` that describe today's no-cache behaviour,
// so these tests compile and fail on behaviour):
//   bool   debugDisableStagedSleepCache      false; true = never store, never reuse
//   int    debugStagedSleepCacheSize         days held
//   int    debugStagedSleepCacheMaxDays      starts at kStagedSleepCacheMaxDays (14)
//   void   debugStagedSleepCacheRekey(int)   re-key every entry to that algo version
//
// RED REASONS TODAY
//   1 reuse        the rescan stages every day again (count N, expected 0)
//   2 law          passes today (nothing is reused, so nothing can differ); it
//                  guards the green phase: reuse must not move a stored byte
//   3 invalidation the rescan stages ALL days, expected only the changed one
//   4 version      no entries exist after the heavy pass (size 0, expected N)
//   5 bound        no entries exist (size 0, expected the bound); the 14 itself
//                  passes today
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/frozen_day_result_fixtures.dart' show dropDb, freshDb;

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

/// Nights of the days (T-3, T-2, T-1), T = today. Each runs 22:00 the evening
/// before -> 07:00 of its day, so the three days are all inside the 3-day raw
/// retention and none of them finalizes (the data edge is yesterday 07:00).
const _nights = 3;

int _at(DateTime day, int hour, [int minute = 0]) =>
    DateTime(day.year, day.month, day.day, hour, minute)
        .millisecondsSinceEpoch ~/
    1000;

DateTime _midnight(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo);
}

/// Day labels, oldest first.
List<String> _days() =>
    [for (var k = _nights; k >= 1; k--) dayLabelOf(_midnight(k))];

Future<void> _seedRows(int from, int to, int Function(int ts) hr) async {
  final db = await LocalDb.instance;
  final b = db.batch();
  for (var ts = from; ts < to; ts++) {
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': hr(ts),
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await b.commit(noResult: true);
}

int _night(int ts) => 52 + (ts % 7);

Future<void> _seedNights() async {
  for (var k = _nights; k >= 1; k--) {
    final d = _midnight(k);
    // The oldest night starts at midnight: an evening on T-4 would be a fourth
    // (finalized, sleepless) day in the pass.
    final from = k == _nights
        ? _at(d, 0)
        : _at(DateTime(d.year, d.month, d.day - 1), 22);
    await _seedRows(from, _at(d, 7), _night);
  }
}

class _Rig {
  _Rig(this.engine);
  final DerivationEngine engine;

  /// Days staged since the last [mark], in dispatch order.
  final List<String> staged = [];

  static Future<_Rig> start(String dbName) async {
    await freshDb(dbName);
    final rig = _Rig(DerivationEngine());
    WorkerAudit.onDispatch = (e) {
      const p = 'sleep-staging ';
      if (e.label.startsWith(p)) rig.staged.add(e.label.substring(p.length));
    };
    await _seedNights();
    return rig;
  }

  Future<void> heavyPass() async {
    final n = await engine.run(_profile, heavy: true);
    expect(n, _nights, reason: 'fixture: the heavy pass derives every night');
  }

  /// The baseline moved: the gate that skips an unchanged rescan is open.
  Future<int> rescan() async {
    await LocalDb.setCursor('baseline_sig', 'moved-by-test');
    return engine.rescanRecent(_profile);
  }

  List<String> takeStaged() {
    final out = [...staged]..sort();
    staged.clear();
    return out;
  }
}

/// Everything a rescan persists, minus the wall-clock stamp.
Future<Map<String, Object?>> _snapshot() async {
  final db = await LocalDb.instance;
  final results = await db.query('day_result', orderBy: 'day_id, algo_version');
  final series = await db.query('metric_series', orderBy: 'date, key');
  return {
    'day_result': [
      for (final r in results)
        {
          for (final e in r.entries)
            if (e.key == 'payload_json')
              e.key: jsonEncode(
                  (jsonDecode(e.value as String) as Map)..remove('computed_at'))
            else if (e.key != 'computed_at')
              e.key: e.value,
        }
    ],
    'metric_series': [for (final r in series) Map<String, Object?>.of(r)],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDown(() async {
    WorkerAudit.reset();
    await dropDb();
  });

  test('1 reuse: a rescan over unchanged inputs stages nothing again',
      () async {
    final rig = await _Rig.start('staged_sleep_reuse_1.db');
    await rig.heavyPass();
    expect(rig.takeStaged(), _days(),
        reason: 'fixture: the heavy pass stages each night exactly once');

    final n = await rig.rescan();
    expect(n, _nights, reason: 'fixture: the rescan re-derives every night');
    expect(rig.takeStaged(), isEmpty,
        reason: 'the heavy pass already staged these nights from these exact '
            'inputs; only baseline-dependent scalars move in a rescan');
  });

  test('2 law: reuse changes no persisted byte (stream == batch)', () async {
    // Same seeds, same passes; the only difference is the cache.
    Future<Map<String, Object?>> run(bool disabled) async {
      final rig = await _Rig.start('staged_sleep_reuse_2_$disabled.db');
      rig.engine.debugDisableStagedSleepCache = disabled;
      await rig.heavyPass();
      await rig.rescan();
      final snap = await _snapshot();
      await dropDb();
      return snap;
    }

    final reused = await run(false);
    final fresh = await run(true);
    expect((reused['day_result'] as List), isNotEmpty);
    expect((reused['metric_series'] as List), isNotEmpty);
    expect(jsonEncode(reused['day_result']), jsonEncode(fresh['day_result']),
        reason: 'day_result payloads after the rescan');
    expect(jsonEncode(reused['metric_series']),
        jsonEncode(fresh['metric_series']),
        reason: 'metric_series rows after the rescan');
  });

  test('3 invalidation: a day whose inputs moved is staged again, others '
      'are reused', () async {
    final rig = await _Rig.start('staged_sleep_reuse_3.db');
    await rig.heavyPass();
    rig.takeStaged();

    // Newest day only: replace ten minutes of its morning in place (same
    // rec_ts, same count, new hr), which moves the input revision. Its
    // neighbours' windows end before this second and their rows are untouched.
    final days = _days();
    final newest = _midnight(1);
    await _seedRows(_at(newest, 3), _at(newest, 3, 10), (_) => 80);

    final n = await rig.rescan();
    expect(n, _nights);
    expect(rig.takeStaged(), [days.last],
        reason: 'only the day with changed inputs is staged again');
    expect(rig.engine.debugStagedSleepCacheSize, _nights,
        reason: 'the re-staged day replaced its entry; none were dropped');
  });

  test('4 version: an entry keyed with another algo version is never reused',
      () async {
    final rig = await _Rig.start('staged_sleep_reuse_4.db');
    await rig.heavyPass();
    rig.takeStaged();
    expect(rig.engine.debugStagedSleepCacheSize, _nights,
        reason: 'fixture: the heavy pass filled the cache');

    rig.engine.debugStagedSleepCacheRekey(kAlgoVersion - 1);
    await rig.rescan();
    expect(rig.takeStaged(), _days(),
        reason: 'entries of another algo version are ignored, every night '
            'is staged afresh');
    expect(rig.engine.debugStagedSleepCacheSize, _nights,
        reason: 'and refilled at the current version (no stale twins kept)');
  });

  test('5 bound: the cache never holds more than its fixed number of days',
      () async {
    expect(DerivationEngine.kStagedSleepCacheMaxDays, 14);
    final rig = await _Rig.start('staged_sleep_reuse_5.db');
    expect(rig.engine.debugStagedSleepCacheMaxDays, 14);

    // Three nights through a bound of two.
    rig.engine.debugStagedSleepCacheMaxDays = _nights - 1;
    await rig.heavyPass();
    rig.takeStaged();
    expect(rig.engine.debugStagedSleepCacheSize, _nights - 1,
        reason: 'filled to the bound, not past it');

    await rig.rescan();
    expect(rig.takeStaged(), hasLength(1),
        reason: 'the one night that fell out of the cache is staged again; '
            'the two that stayed are reused');
    expect(rig.engine.debugStagedSleepCacheSize, _nights - 1,
        reason: 'still at the bound after the rescan');
  });
}
