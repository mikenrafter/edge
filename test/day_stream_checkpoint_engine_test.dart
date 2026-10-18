// Streaming RR and the day curves in the checkpoint (phase 1, ALL RED), engine
// layer: a real database, fresh engines between passes (a headless wake, a cold
// start), and a forced full pass as the oracle. See
// test/day_stream_state_test.dart for the pure states these use.
//
// What a resumed pass must do, and how this file observes it:
//
//  * PERSISTED OUTPUT DOES NOT CHANGE. Everything in `day_result` (payload,
//    including `clinical.irregular_24h`, `daytime_hrv`, `hrv_day`, `resp_day`)
//    and `metric_series` after any chain of resumed passes, random chunkings
//    included, equals what one forced full pass over the same rows stores, and
//    the checkpoint bytes equal too.
//  * RR IS NOT RE-READ. The engine reports `counts.rr_rows_read` in
//    `DerivationEngine.perf.summary()`: the `decoded_rr` rows the prepare step
//    read for the pass (all of the day on a full pass; on a resumed pass only
//    those at or after the checkpoint's `cpRecTs`, plus a small slack for any
//    unsettled tail the implementation chooses to re-read). Only on a day with
//    no night: a night's RR is still read for the sleep window (the night path
//    is not streamed in this step).
//  * THE CURVES FOLD ONLY THE TAIL. The engine reports
//    `counts.curve_beats_folded`: RR beats handed to the three day-curve states
//    this pass (the whole day on a full pass, the tail on a resumed one).
//  * RR BEHIND THE SETTLED EDGE FORCES A REFOLD: a replaced, late or evicted
//    beat in a closed bucket changes its revision, so the pass is full
//    (`full revised:`), reads the whole day, and still stores what a full pass
//    stores.
//  * THE LAYOUT VERSION MOVED: a checkpoint written at layout 2 (no RR state) is
//    not resumed (`full fmt`).
//
// And the pipeline seam: `deriveDayBundle` takes the day's 24/7 screen from the
// input key `day_irregular` (the persisted metric envelope, as the streaming
// state produces it) instead of running `correctRr` + `irregularBeatScreen`
// over `day_rr_ms` / `day_rr_ts_ms`; with the key, whole-day RR arrays are not
// needed and the bundle is byte-identical to the batch bundle.
//
// STUBS: none added by this file beyond those of day_stream_state_test.dart
// (`DayRrState`, `DayCurveStates`, ...); the counters and the `day_irregular`
// key do not exist yet, so these fail on the missing counter / the ignored key.
//
// NOT pinned (cheap to add once the day path is green): the NIGHT path. The
// sleep window moves every pass, `correctRr` over the sleep RR is windowed by
// it, and a streamed night would need its own window-free RR state; the night's
// RR is read in full here.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/day_stream_fixture.dart';
import 'support/incremental_day_fixture.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── the pipeline seam ─────────────────────────────────────────────────────

  group('deriveDayBundle takes the day screen from day_irregular', () {
    Map<String, dynamic> withDayBeats(Beats b) {
      final input = copyDay(incrementalDay());
      input['day_rr_ts_ms'] = b.ts;
      input['day_rr_ms'] = b.rr;
      return input;
    }

    Object? irregular(Map<String, dynamic> bundle) =>
        ((bundle['clinical'] as Map)['irregular_24h']);

    test('the envelope handed in is the one published, and the whole-day RR is '
        'not needed (no key = the batch screen, unchanged)', () {
      final beats = synthBeats(const SynthBeats(
          seed: 3,
          seconds: 3 * 3600,
          ectopicPerMin: 0.05,
          missedPerMin: 0,
          extraPerMin: 0,
          noiseRunPerMin: 0,
          gapPerHour: 0,
          irregularBurst: (0, 3 * 3600),
          irregularRangeMs: (600, 1000)));
      final input = withDayBeats(beats);
      final oracle = deriveDayBundle(copyDay(input));
      final screen = irregular(oracle) as Map;
      expect((screen['value'] as Map)['flag'], isTrue,
          reason: 'fixture: the batch screen is present and flagged');

      // The same day with its whole-day RR gone and the envelope handed in.
      final lean = copyDay(input);
      lean['day_rr_ts_ms'] = <double>[];
      lean['day_rr_ms'] = <double>[];
      expect(jsonEncode(irregular(deriveDayBundle(copyDay(lean)))),
          isNot(jsonEncode(screen)),
          reason: 'guard: without the key an empty day has no screen');
      lean['day_irregular'] = screen;
      final got = deriveDayBundle(lean);
      expect(jsonEncode(irregular(got)), jsonEncode(screen));
      expect(jsonEncode(got), jsonEncode(oracle),
          reason: 'nothing else in the bundle read the whole-day RR');
    });

    test('an absent screen handed in stays absent, and is not recomputed from '
        'whatever RR the input also carries', () {
      final beats = synthBeats(const SynthBeats(seed: 5, seconds: 2 * 3600));
      final input = withDayBeats(beats);
      final absent = {
        'value': '—',
        'confidence': 0.0,
        'tier': 'ESTIMATE',
        'inputs_used': ['rr_cleaned'],
        'note': 'too few clean beats for an irregular-rhythm screen',
      };
      input['day_irregular'] = absent;
      expect(jsonEncode(irregular(deriveDayBundle(input))), jsonEncode(absent));
    });
  });

  // ── the engine ────────────────────────────────────────────────────────────

  group('engine resume with streaming RR and curves', () {
    late int start;
    late String day;
    late Beats beats;
    late Accel accel;

    // Three hours first (the closed boundary is 15 minutes short of it), then
    // twenty minutes more: the tail is a small part of the day.
    const first = 3 * 3600;
    const second = first + 1200;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'day_stream_checkpoint_engine_test.db';
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
      // Yesterday from 08:00 (a bucket boundary): pending, never finalized,
      // whatever time of day the test runs.
      start = midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
      beats = synthBeats(SynthBeats(
          seed: 17,
          startSec: start,
          seconds: 4 * 3600,
          irregularBurst: (4000, 7000)));
      accel = synthAccel(23, start, start + 4 * 3600 + 60);
    });
    tearDownAll(wipe);

    Future<void> rows(int fromOffset, int toOffset) =>
        writeSeconds(beats, accel, start + fromOffset, start + toOffset);

    int beatsIn(int fromSec, int toSec) => beats.between(fromSec, toSec).length;

    /// The `decoded_rr` rows the database holds in `[fromSec, toSec)` now
    /// (after a test changed some).
    Future<int> beatRowsIn(int fromSec, int toSec) async {
      final db = await LocalDb.instance;
      final r = await db.rawQuery(
          'SELECT COUNT(*) AS n FROM decoded_rr WHERE rec_ts >= ? AND rec_ts < ?',
          [fromSec, toSec]);
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

    Future<DayCheckpoint?> checkpoint() => LocalDb.dayCheckpoint(day, kAlgoVersion);

    /// A forced full pass over what the database holds now: the oracle. It
    /// rewrites the day and its checkpoint from the first second.
    Future<int?> oracle() async {
      final e = DerivationEngine();
      await e.run(_profile, force: true);
      return _count(e, 'rr_rows_read');
    }

    List<String> ckptLines(List<String> log) => [
          for (final l in log)
            if (l.contains('[perf] checkpoint $day'))
              l.substring(l.indexOf('[perf] checkpoint')),
        ];

    /// A fresh engine's pass over what the database holds, its checkpoint line
    /// and its counters.
    Future<({List<String> lines, int? rrRead, int? curveFolded})> pass() async {
      final log = <String>[];
      final e = DerivationEngine(log: log.add);
      await e.run(_profile);
      return (
        lines: ckptLines(log),
        rrRead: _count(e, 'rr_rows_read'),
        curveFolded: _count(e, 'curve_beats_folded'),
      );
    }

    test('fixture (a guard, passes today): the day has a screen, curves and '
        'daytime HRV worth pinning, and no night', () async {
      await rows(0, first);
      await DerivationEngine().run(_profile);
      final payload = (await stored())['payload'] as Map;
      final screen = (payload['clinical'] as Map)['irregular_24h'] as Map;
      expect(screen['value'], isA<Map>(), reason: 'a present screen');
      final series = payload['series'] as Map;
      expect(((series['hrv_day'] as Map)['v'] as List), isNotEmpty);
      expect(((series['resp_day'] as Map)['v'] as List), isNotEmpty);
      expect((payload['daytime_hrv'] as Map)['n_buckets'], greaterThan(5));
      expect((payload['sleep'] as Map)['window'] as Map, containsPair('value', '—'),
          reason: 'no sleep window: the day path is the only RR reader');
    });

    test('a headless wake reads only the beats after the checkpoint, folds only '
        'those into the curves, and stores what a full pass stores', () async {
      await rows(0, first);
      final one = await pass();
      expect(one.lines, ['[perf] checkpoint $day full none']);
      final whole1 = beatsIn(start, start + first);
      expect(one.rrRead, whole1, reason: 'a full pass reads every beat of the day');
      expect(one.curveFolded, whole1, reason: 'and folds every one into the curves');
      final cp1 = (await checkpoint())!;
      expect(cp1.fmt, kDayCheckpointFmt);

      await rows(first, second);
      final two = await pass();
      expect(two.lines.single, matches(RegExp(r'resume folded=\d+')));
      final tail = beatsIn(cp1.cpRecTs, start + second);
      final whole2 = beatsIn(start, start + second);
      expect(tail, lessThan(whole2 ~/ 3), reason: 'fixture: the tail is a small part');
      expect(two.rrRead, isNotNull, reason: 'the engine reports rr_rows_read');
      expect(two.rrRead!, lessThanOrEqualTo(tail + 200),
          reason: 'only the beats after the checkpoint (and a small tail)');
      expect(two.rrRead!, greaterThanOrEqualTo(tail),
          reason: 'every beat after the checkpoint');
      expect(two.curveFolded, isNotNull, reason: 'the engine reports curve_beats_folded');
      expect(two.curveFolded!, lessThanOrEqualTo(tail + 200));
      expect(two.curveFolded!, greaterThanOrEqualTo(tail));

      final cp2 = (await checkpoint())!;
      final resumed = await stored();
      final oracleRead = await oracle();
      expect(oracleRead, whole2, reason: 'the oracle pass reads the whole day');
      expect(await stored(), equals(resumed),
          reason: 'resuming changes no stored figure');
      final cp3 = (await checkpoint())!;
      expect(cp3.cpRecTs, cp2.cpRecTs);
      expect(cp3.state, cp2.state,
          reason: 'resumed-then-advanced is byte-identical to folded at once');
    });

    test('random chunkings: passes of random size, a fresh engine each, equal to '
        'a forced full pass after every one', () async {
      final r = math.Random(5);
      var upTo = 0;
      var hadCheckpoint = false;
      var passes = 0;
      while (upTo < 3 * 3600 + 1800 && passes < 7) {
        final from = upTo;
        upTo = math.min(3 * 3600 + 1800, upTo + 400 + r.nextInt(2400));
        await rows(from, upTo);
        final cpBefore = await checkpoint();
        final out = await pass();
        passes++;
        if (cpBefore != null) {
          expect(out.lines.single, matches(RegExp(r'resume folded=\d+')),
              reason: 'pass $passes (to +${upTo}s)');
          final tail = beatsIn(cpBefore.cpRecTs, start + upTo);
          expect(out.rrRead, isNotNull, reason: 'pass $passes reports rr_rows_read');
          expect(out.rrRead!, lessThanOrEqualTo(tail + 200), reason: 'pass $passes');
          expect(out.curveFolded!, lessThanOrEqualTo(tail + 200), reason: 'pass $passes');
        }
        hadCheckpoint = hadCheckpoint || await checkpoint() != null;
        final got = await stored();
        final cp = await checkpoint();
        await oracle();
        expect(await stored(), equals(got), reason: 'pass $passes (to +${upTo}s)');
        expect((await checkpoint())?.state, cp?.state,
            reason: 'pass $passes: the checkpoint is what a full fold writes');
      }
      expect(hadCheckpoint, isTrue);
      expect(passes, greaterThanOrEqualTo(4));
    });

    group('beats behind the settled edge force a refold', () {
      Future<List<String>> scenario(Future<void> Function() change) async {
        await rows(0, first);
        await pass();
        expect(await checkpoint(), isNotNull);
        await change();
        await rows(first, second);
        final out = await pass();
        expect(out.lines.single, contains('full revised:'));
        expect(out.rrRead, isNotNull, reason: 'the engine reports rr_rows_read');
        expect(out.rrRead, await beatRowsIn(start, start + second),
            reason: 'a refold reads the whole day');
        final got = await stored();
        await oracle();
        expect(await stored(), equals(got),
            reason: 'the refolded pass stores what a full pass stores');
        return out.lines;
      }

      test('a beat replaced', () async {
        await scenario(() async {
          final db = await LocalDb.instance;
          await db.rawUpdate(
              'UPDATE decoded_rr SET rr_ms = rr_ms + 233 WHERE rec_ts >= ? AND rec_ts < ?',
              [start + 500, start + 520]);
        });
      });

      test('a late beat into a second the checkpoint had folded without one',
          () async {
        await scenario(() async {
          final db = await LocalDb.instance;
          await db.rawInsert(
              'INSERT OR REPLACE INTO decoded_rr '
              '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
              "VALUES ('', ?, ?, 7, ?, 640)",
              [(start + 1000) * 1000, start + 1000, (start + 1000) * 1000]);
        });
      });

      test('beats evicted', () async {
        await scenario(() async {
          final db = await LocalDb.instance;
          await db.delete('decoded_rr',
              where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [start + 100, start + 400]);
        });
      });
    });

    test('a beat replaced AFTER the checkpoint edge does not force a refold',
        () async {
      await rows(0, first);
      await pass();
      final cp = (await checkpoint())!;
      await rows(first, second);
      final db = await LocalDb.instance;
      await db.rawUpdate(
          'UPDATE decoded_rr SET rr_ms = rr_ms + 233 WHERE rec_ts >= ? AND rec_ts < ?',
          [cp.cpRecTs + 600, cp.cpRecTs + 620]);
      final out = await pass();
      expect(out.lines.single, matches(RegExp(r'resume folded=\d+')));
      final tail = beatsIn(cp.cpRecTs, start + second);
      expect(out.rrRead, isNotNull);
      expect(out.rrRead!, lessThanOrEqualTo(tail + 200));
      final got = await stored();
      await oracle();
      expect(await stored(), equals(got));
    });

    test('a checkpoint written before RR was carried (layout 2) is not resumed',
        () async {
      await rows(0, first);
      await pass();
      final db = await LocalDb.instance;
      await db.update('day_checkpoint', {'fmt': 2});
      await rows(first, second);
      final out = await pass();
      expect(out.lines.single, contains('full fmt'),
          reason: 'the version bump retires every earlier blob');
      final got = await stored();
      await oracle();
      expect(await stored(), equals(got));
    });

    test('a blob with damaged RR state is ignored, never half read', () async {
      await rows(0, first);
      await pass();
      final cp = (await checkpoint())!;
      final bad = Uint8List.fromList(cp.state);
      // Damage a byte near the end (where the RR and curve parts live) and
      // leave the checksum alone: the blob must be refused as a whole.
      bad[bad.length - 40] ^= 0x55;
      await (await LocalDb.instance).update('day_checkpoint', {'state': bad});
      await rows(first, second);
      final out = await pass();
      expect(out.lines.single, contains('full unreadable_state'));
      final got = await stored();
      await oracle();
      expect(await stored(), equals(got));
      expect(out.rrRead, isNotNull);
      expect(out.rrRead, beatsIn(start, start + second));
    });
  });

  // ── a night in the day ────────────────────────────────────────────────────

  group('a day with a night resumes and stores what a full pass stores', () {
    late DateTime mid;
    late String day;
    late int counter;
    int h(double hours) =>
        mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

    // Asleep 23:00 to 06:30, awake after.
    bool asleep(int t) => t >= h(-1) && t < h(6.5);

    Future<void> rows(double from, double to) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      for (var ts = h(from); ts < h(to); ts++) {
        final s = asleep(ts);
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_onehz '
          '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
          "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, ?, ?, ?, ?, ?, 1, 1, 3000, 'gen4')",
          [
            ts * 1000,
            ts,
            counter++,
            s ? 52 + (ts % 7) : 80 + (ts ~/ 60) % 20 + ts % 3,
            s ? 0.0 : .3 * math.sin(ts * .21),
            s ? 0.0 : .2 * math.cos(ts * .13),
            s ? 1.0 : 1 + .05 * math.sin(ts * .07),
          ],
        );
        // One beat a second, with respiratory modulation and an ectopic every
        // 211 s: the night's HRV and the day's screen both have something to say.
        final rr = ts % 211 == 0
            ? 600
            : (1000 + 45 * math.sin(2 * math.pi * 0.24 * ts) + (ts % 5) * 3).round();
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_rr '
          '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
          "VALUES ('', ?, ?, 0, ?, ?)",
          [ts * 1000, ts, ts * 1000, rr],
        );
      }
      await b.commit(noResult: true);
    }

    Future<Map<String, dynamic>> stored() async {
      final row = (await LocalDb.dayResult(day))!;
      final payload =
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      payload.remove('computed_at');
      return {
        'payload': payload,
        for (final k in ['rhr', 'rmssd', 'readiness', 'partial', 'finalized'])
          k: row[k],
      };
    }

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'day_stream_checkpoint_night_test.db';
    });

    Future<void> wipe() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    }

    setUp(() async {
      await wipe();
      counter = 0;
      final now = DateTime.now();
      mid = DateTime(now.year, now.month, now.day - 1);
      day = dayLabelOf(mid);
    });
    tearDownAll(wipe);

    test('passes at 03:00, 05:30 and 09:00, a fresh engine each', () async {
      var from = -2.0;
      for (final upTo in [3.0, 5.5, 9.0]) {
        await rows(from, upTo);
        from = upTo;
        final log = <String>[];
        final before = await LocalDb.dayCheckpoint(day, kAlgoVersion);
        final e = DerivationEngine(log: log.add);
        await e.run(_profile);
        final lines = [
          for (final l in log)
            if (l.contains('[perf] checkpoint $day')) l,
        ];
        expect(lines, isNotEmpty, reason: 'to $upTo');
        if (upTo > 3.0) {
          expect(lines.single, contains('resume folded='), reason: 'to $upTo');
          // One beat a second: the beats after the checkpoint are its seconds.
          final tail = h(upTo) - before!.cpRecTs;
          final folded = _count(e, 'curve_beats_folded');
          expect(folded, isNotNull,
              reason: 'the engine reports curve_beats_folded (to $upTo)');
          expect(folded!, lessThanOrEqualTo(tail + 200),
              reason: 'the curves fold the tail, the night included (to $upTo)');
          final read = _count(e, 'rr_rows_read');
          expect(read, isNotNull, reason: 'the engine reports rr_rows_read');
          expect(read, greaterThan(0),
              reason: 'the night\'s own beats are still read for the sleep window');
        }
      }
      final got = await stored();
      expect(((got['payload'] as Map)['scalars'] as Map)['tst_min'], isNotNull,
          reason: 'fixture: a night was found');
      await DerivationEngine().run(_profile, force: true);
      expect(await stored(), equals(got),
          reason: 'the chain stores what one full pass stores, the night\'s '
              'HRV and the day\'s screen included');
    });
  });
}

int? _count(DerivationEngine e, String name) =>
    ((e.perf.summary()['counts'] as Map)[name] as num?)?.toInt();
