// RED (phase 1): in a WARM process the day's RR work follows the new beats.
//
// One DerivationEngine is kept across passes (it holds `_calculationStates`),
// beats are appended between passes, and:
//
//  1. EXACTNESS (guard, may pass today): after every warm pass the stored
//     24/7 irregular screen (`clinical.irregular_24h`, diagnostics included),
//     the day curves (`hrv_day`, `resp_day`), daytime HRV and the whole stored
//     day equal a single cold batch derive (fresh engine, force) over the same
//     rows.
//  2. WORK (RED): on the second and later warm passes
//       `day_rr_beats_folded`  <= new beats + seam allowance   (counter to add:
//                                  beats handed to the DayRrState this pass)
//       `day_rr_batch_runs`    == 0                            (counter to add:
//                                  whole-day correctRr + irregularBeatScreen
//                                  batch runs this pass)
//       `curve_beats_folded`, `rr_rows_read` <= new beats + seam allowance
//     today the warm pass reads and re-processes the whole day.
//  3. FALLBACKS: a warm pass where beats BEHIND the folded tail changed
//     (replaced, late-inserted, evicted) must still match the batch (guard),
//     and must say it ran the batch: `day_rr_batch_runs == 1` (RED, counter).
//     A wearable day never streams: both new counters are 0/absent (guard).
//
// Seam allowance: the checkpoint settles 15 minutes (a rev bucket) behind the
// newest beat, so a warm pass may re-fold up to ~900 beats it had not yet
// closed. 1000 is still ~1/10 of the whole day here.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_edge/compute/day_checkpoint_policy.dart'
    show kRevBucketSec, kRrFoldGuardSec;

import 'package:flutter_test/flutter_test.dart';
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

const _seam = 1000;

int? _count(DerivationEngine e, String name) =>
    ((e.perf.summary()['counts'] as Map)[name] as num?)?.toInt();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int start;
  late String day;
  late Beats beats;
  late Accel accel;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'day_rr_warm_stream_test.db';
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
    beats = synthBeats(SynthBeats(
        seed: 17,
        startSec: start,
        seconds: 4 * 3600,
        irregularBurst: (4000, 7000)));
    accel = synthAccel(23, start, start + 4 * 3600 + 60);
  });
  tearDownAll(wipe);

  Future<void> rows(int from, int to) =>
      writeSeconds(beats, accel, start + from, start + to);
  int beatsIn(int from, int to) =>
      beats.between(start + from, start + to).length;

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

  /// The pinned parts, each as exact text.
  Map<String, String> parts(Map<String, dynamic> s) {
    final payload = s['payload'] as Map;
    final series = payload['series'] as Map;
    return {
      'irregular_24h': jsonEncode((payload['clinical'] as Map)['irregular_24h']),
      'hrv_day': jsonEncode(series['hrv_day']),
      'resp_day': jsonEncode(series['resp_day']),
      'daytime_hrv': jsonEncode(payload['daytime_hrv']),
    };
  }

  /// Cold batch oracle: a fresh engine, forced, over the rows as they are.
  Future<Map<String, dynamic>> coldBatch() async {
    await DerivationEngine().run(_profile, force: true);
    return stored();
  }

  void expectSameAsBatch(Map<String, dynamic> warm, Map<String, dynamic> cold,
      String why) {
    final w = parts(warm), c = parts(cold);
    for (final k in c.keys) {
      expect(w[k], c[k], reason: '$k: $why');
    }
    expect(warm, equals(cold), reason: 'whole stored day: $why');
  }

  const steps = [3 * 3600, 3 * 3600 + 1200, 3 * 3600 + 2400, 4 * 3600];

  test('warm chain: exact vs a cold batch after every pass (guard)', () async {
    final warm = DerivationEngine();
    var prev = 0;
    for (final upTo in steps) {
      await rows(prev, upTo);
      prev = upTo;
      await warm.run(_profile);
      final got = await stored();
      final screen = (((got['payload'] as Map)['clinical'])
          as Map)['irregular_24h'] as Map;
      expect(screen['value'], isA<Map>(), reason: 'fixture: a present screen');
      expectSameAsBatch(got, await coldBatch(), 'warm pass to +${upTo}s');
    }
  });

  test('warm passes 2.. fold only the new beats, no whole-day batch (RED)',
      () async {
    final warm = DerivationEngine();
    var prev = 0;
    var pass = 0;
    for (final upTo in steps) {
      await rows(prev, upTo);
      await warm.run(_profile);
      pass++;
      if (pass >= 2) {
        final fresh = beatsIn(prev, upTo);
        final whole = beatsIn(0, upTo);
        // The unsettled tail, by the checkpoint's own rule: folded beats end at
        // the last closed rev bucket before the previous pass's newest beat,
        // minus the fold guard (day_checkpoint_policy.dart).
        final settled = ((start + prev - 1) ~/ kRevBucketSec) * kRevBucketSec -
            kRrFoldGuardSec -
            start;
        final seam = beatsIn(math.max(0, settled), prev);
        expect(fresh + seam, lessThan(whole ~/ 2),
            reason: 'fixture: new beats are a small part of the day');
        final why = 'warm pass $pass (+$fresh new of $whole)';
        final folded = _count(warm, 'day_rr_beats_folded');
        expect(folded, isNotNull,
            reason: 'the engine reports day_rr_beats_folded: $why');
        expect(folded!, lessThanOrEqualTo(fresh + seam), reason: why);
        expect(folded, greaterThanOrEqualTo(fresh), reason: why);
        expect(_count(warm, 'day_rr_batch_runs') ?? 0, 0,
            reason: 'no whole-day irregular/correctRr batch: $why');
        expect(_count(warm, 'curve_beats_folded') ?? whole,
            lessThanOrEqualTo(fresh + seam),
            reason: 'curves fold the tail only: $why');
        // Rows are read by record time, and a record's beats sit up to the fold
        // guard before its own second: one guard window more than the beats.
        final guardRows =
            beatsIn(math.max(0, settled - kRrFoldGuardSec), math.max(0, settled));
        expect(_count(warm, 'rr_rows_read') ?? whole,
            lessThanOrEqualTo(fresh + seam + guardRows),
            reason: 'RR rows are not re-read: $why');
      }
      prev = upTo;
    }
  });

  group('beats behind the folded tail: batch fallback, still exact', () {
    final changes = <String, Future<void> Function(int start)>{
      'a beat replaced': (s) async {
        final db = await LocalDb.instance;
        await db.rawUpdate(
            'UPDATE decoded_rr SET rr_ms = rr_ms + 233 '
            'WHERE rec_ts >= ? AND rec_ts < ?',
            [s + 500, s + 520]);
      },
      'a backfill inserted before the tail': (s) async {
        final db = await LocalDb.instance;
        await db.rawInsert(
            'INSERT OR REPLACE INTO decoded_rr '
            '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
            "VALUES ('', ?, ?, 7, ?, 640)",
            [(s + 1000) * 1000, s + 1000, (s + 1000) * 1000]);
      },
      'beats evicted': (s) async {
        final db = await LocalDb.instance;
        await db.delete('decoded_rr',
            where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [s + 100, s + 400]);
      },
    };
    for (final e in changes.entries) {
      test(e.key, () async {
        final warm = DerivationEngine();
        await rows(0, steps[0]);
        await warm.run(_profile);
        await rows(steps[0], steps[1]);
        await warm.run(_profile);
        await e.value(start);
        await rows(steps[1], steps[2]);
        await warm.run(_profile);
        expectSameAsBatch(await stored(), await coldBatch(), e.key);
      });

      test('${e.key}: reports the batch run (RED)', () async {
        final warm = DerivationEngine();
        await rows(0, steps[0]);
        await warm.run(_profile);
        await rows(steps[0], steps[1]);
        await warm.run(_profile);
        await e.value(start);
        await rows(steps[1], steps[2]);
        await warm.run(_profile);
        expect(_count(warm, 'day_rr_batch_runs'), 1,
            reason: '${e.key}: the whole-day batch ran exactly once');
      });
    }
  });

  test('a pass after the fallback streams again (RED)', () async {
    final warm = DerivationEngine();
    await rows(0, steps[0]);
    await warm.run(_profile);
    final db = await LocalDb.instance;
    await db.rawUpdate(
        'UPDATE decoded_rr SET rr_ms = rr_ms + 233 '
        'WHERE rec_ts >= ? AND rec_ts < ?',
        [start + 500, start + 520]);
    await rows(steps[0], steps[1]);
    await warm.run(_profile);
    await rows(steps[1], steps[2]);
    await warm.run(_profile);
    final fresh = beatsIn(steps[1], steps[2]);
    expect(_count(warm, 'day_rr_batch_runs') ?? 0, 0);
    expect(_count(warm, 'day_rr_beats_folded'), isNotNull);
    expect(_count(warm, 'day_rr_beats_folded')!, lessThanOrEqualTo(fresh + _seam));
    expectSameAsBatch(await stored(), await coldBatch(), 'resumed streaming');
  });
}
