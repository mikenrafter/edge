// Resuming a day from its stored checkpoint. Two layers:
//
//  * the state codec and the folds behind it, pure: a day folded in random
//    pieces, written out and read back between pieces, is byte-for-byte the
//    state one fold of the whole day gives, and reads the same as the batch
//    readers;
//  * the engine, against a real database: a fresh engine (a headless wake, a
//    cold start) picks the day up from the checkpoint, stores exactly what a
//    full pass stores, and falls back to a full pass for every change the
//    design lists (design report 3.4).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/day_activity_state.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── pure layer ──────────────────────────────────────────────────────────────

class _Day {
  _Day(this.ts, this.hr, this.ax, this.ay, this.az, this.step);
  final List<int> ts, hr, step;
  final List<double> ax, ay, az;
  int get length => ts.length;
}

/// A day with every shape the folds treat specially: no-HR seconds, spikes the
/// plausibility ceiling rejects, off-wrist gaps longer than the run-split gap,
/// seconds with no gravity vector, a step counter that wraps, resets and goes
/// missing.
_Day _synthDay({
  required int start,
  required int seconds,
  int seed = 7,
  bool counter = true,
}) {
  final rnd = math.Random(seed);
  final ts = <int>[], hr = <int>[], step = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  var t = start;
  var c = 65500;
  for (var i = 0; i < seconds; i++) {
    if (i > 0 && i % 4001 == 0) t += 180; // an off-wrist gap
    ts.add(t++);
    final r = rnd.nextInt(100);
    hr.add(r < 4 ? 0 : (r < 6 ? 250 : 55 + (i ~/ 90) % 70 + rnd.nextInt(5)));
    if (rnd.nextInt(50) == 0) {
      ax.add(0);
      ay.add(0);
      az.add(0);
    } else {
      ax.add(.3 * math.sin(i * .21) + rnd.nextDouble() * .05);
      ay.add(.2 * math.cos(i * .13));
      az.add(1 + .05 * math.sin(i * .07));
    }
    if (!counter) {
      step.add(-1);
    } else if (i % 997 > 900) {
      step.add(-1);
    } else {
      if (i == 3001) {
        c = 40000; // a reset: the next delta is unreadable and must be dropped
      } else if (i == 3002) {
        c = 0;
      } else {
        c = (c + rnd.nextInt(3)) % 65536; // wraps through 65535 -> 0
      }
      step.add(c);
    }
  }
  return _Day(ts, hr, ax, ay, az, step);
}

const _on = 1000, _off = 5000;

DayResumeState _foldAll(_Day d, {int on = 0, int off = 0, int? modulus = 65536}) {
  final s = DayResumeState();
  expect(
    s.appendTail(
      ts: d.ts,
      hr: d.hr,
      ax: d.ax,
      ay: d.ay,
      az: d.az,
      stepCounter: d.step,
      sleepOnsetSec: on,
      sleepOffsetSec: off,
      age: 35,
      stepModulus: modulus,
    ),
    isTrue,
  );
  return s;
}

/// Folds [d] in the given pieces, writing the state out and reading it back
/// between every two pieces: what a restart between passes does.
Uint8List _foldInPieces(_Day d, Iterable<int> sizes,
    {int on = 0, int off = 0, int? modulus = 65536}) {
  Uint8List? blob;
  var at = 0;
  for (final n in sizes) {
    if (at >= d.length) break;
    final hi = math.min(d.length, at + n);
    final next = foldDayCheckpoint(
      base: blob,
      alreadyFolded: at,
      ts: d.ts.sublist(at, hi),
      hr: d.hr.sublist(at, hi),
      ax: d.ax.sublist(at, hi),
      ay: d.ay.sublist(at, hi),
      az: d.az.sublist(at, hi),
      stepCounter: d.step.sublist(at, hi),
      sleepOnsetSec: on,
      sleepOffsetSec: off,
      age: 35,
      stepModulus: modulus,
    );
    expect(next, isNotNull, reason: 'piece [$at,$hi) folded');
    blob = next;
    at = hi;
  }
  expect(at, d.length, reason: 'the pieces cover the day');
  return blob!;
}

Substrate _substrate(_Day d) => Substrate(
      tsSec: d.ts,
      hr: d.hr,
      rrTsMs: const [],
      rrMs: const [],
      ax: d.ax,
      ay: d.ay,
      az: d.az,
      spo2Red: List.filled(d.length, 0),
      spo2Ir: List.filled(d.length, 0),
      skinTemp: List.filled(d.length, 0),
      skinContact: List.filled(d.length, 0),
      stepCount: d.step,
      deviceFamily: 'gen5',
    );

List<int> _chunks(math.Random r, int total) {
  final out = <int>[];
  var left = total;
  while (left > 0) {
    // From a single second to a couple of hours, so seams land everywhere.
    final n = 1 + r.nextInt(r.nextBool() ? 40 : 7000);
    out.add(n);
    left -= n;
  }
  return out;
}

Uint8List _bytes(void Function(ResumeWriter) write) {
  final w = ResumeWriter();
  write(w);
  return w.takeBytes();
}

/// [blob] rewritten as another layout version, checksum and all, so only the
/// version differs.
Uint8List _withFmt(Uint8List blob, int fmt) {
  final out = Uint8List.fromList(blob);
  final d = ByteData.sublistView(out);
  d.setInt32(4, fmt);
  d.setUint32(out.length - 4, checksum32(out, out.length - 4));
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('state codec', () {
    late _Day day;
    late Uint8List blob;
    setUpAll(() {
      day = _synthDay(start: 1760000000, seconds: 9000);
      blob = encodeDayResumeState(_foldAll(day, on: _on, off: _off));
    });

    test('round-trips to the identical bytes', () {
      final back = decodeDayResumeState(blob)!;
      expect(back.folded, day.length);
      expect(encodeDayResumeState(back), blob);
    });

    test('an empty state round-trips', () {
      final empty = encodeDayResumeState(DayResumeState());
      expect(decodeDayResumeState(empty)!.folded, 0);
    });

    test('another layout version is ignored, never misread', () {
      expect(decodeDayResumeState(_withFmt(blob, kDayCheckpointFmt + 1)), isNull);
      expect(decodeDayResumeState(_withFmt(blob, 0)), isNull);
      expect(decodeDayResumeState(_withFmt(blob, kDayCheckpointFmt)), isNotNull,
          reason: 'the rewrite helper keeps the blob valid otherwise');
      // The fold refuses a base it cannot read rather than starting over.
      expect(
        foldDayCheckpoint(
          base: _withFmt(blob, kDayCheckpointFmt + 1),
          alreadyFolded: day.length,
          ts: const [],
          hr: const [],
          ax: const [],
          ay: const [],
          az: const [],
          stepCounter: const [],
          sleepOnsetSec: _on,
          sleepOffsetSec: _off,
          age: 35,
          stepModulus: 65536,
        ),
        isNull,
      );
    });

    test('torn, damaged, foreign and padded blobs are ignored', () {
      expect(decodeDayResumeState(Uint8List(0)), isNull);
      expect(decodeDayResumeState(Uint8List(12)), isNull);
      for (final cut in [1, 4, 5, blob.length ~/ 2, blob.length - 1]) {
        expect(decodeDayResumeState(Uint8List.sublistView(blob, 0, blob.length - cut)),
            isNull, reason: 'cut $cut');
      }
      for (final at in [0, 9, 40, blob.length ~/ 2, blob.length - 5]) {
        final bad = Uint8List.fromList(blob)..[at] ^= 0x01;
        expect(decodeDayResumeState(bad), isNull, reason: 'flip at $at');
      }
      expect(decodeDayResumeState(Uint8List.fromList([...blob, 0])), isNull);
      expect(decodeDayResumeState(Uint8List.fromList(utf8.encode('not a blob at all'))),
          isNull);
    });

    test('a count that asks for more than the blob holds is ignored', () {
      // Re-sign a blob whose first map count is absurd: not the checksum's job
      // to catch, the reader's.
      final bad = Uint8List.fromList(blob);
      final d = ByteData.sublistView(bad);
      // magic(4) fmt(4) folded(8) | hr: 2 lanes(16) n sleepOn sleepOff(24) age(1+8)
      // validSum(8) validCount(8) max(1+8) min(1+8) -> window count.
      const windowCount = 4 + 4 + 8 + 16 + 24 + 9 + 8 + 8 + 9 + 9;
      d.setInt32(windowCount, 0x7fffffff);
      d.setUint32(bad.length - 4, checksum32(bad, bad.length - 4));
      expect(decodeDayResumeState(bad), isNull);
    });

    test('parts that disagree about how much they folded are ignored', () {
      final a = _foldAll(_synthDay(start: 1760000000, seconds: 500));
      final b = _foldAll(_synthDay(start: 1760000000, seconds: 400));
      final w = ResumeWriter()
        ..i32(0x4f534443)
        ..i32(kDayCheckpointFmt)
        ..i64(a.folded);
      a.hrPipeline.write(w);
      b.hrActivity.write(w); // folded 400, the header says 500
      a.motion.write(w);
      a.steps.write(w);
      final body = w.takeBytes();
      final out = Uint8List(body.length + 4)..setRange(0, body.length, body);
      ByteData.sublistView(out).setUint32(body.length, checksum32(body, body.length));
      expect(decodeDayResumeState(out), isNull);
    });
  });

  group('folding in pieces equals folding at once', () {
    test('random chunking, restart from the blob between pieces', () {
      for (final seed in [1, 2, 3, 4, 5, 6]) {
        final day = _synthDay(start: 1760000000, seconds: 21000, seed: seed);
        final r = math.Random(seed * 31);
        final once = encodeDayResumeState(_foldAll(day, on: _on, off: _off));
        final pieces = _foldInPieces(day, _chunks(r, day.length), on: _on, off: _off);
        expect(pieces, once, reason: 'seed $seed');
      }
    });

    test('the same state live syncs over the whole arrays reach', () {
      final day = _synthDay(start: 1760000000, seconds: 12000);
      final live = DayResumeState();
      live.hrPipeline.sync(day.ts, day.hr,
          sleepOnsetSec: _on, sleepOffsetSec: _off, age: 35);
      live.hrActivity.sync(day.ts, day.hr,
          sleepOnsetSec: _on, sleepOffsetSec: _off, age: 35);
      live.motion.sync(day.ts, day.ax, day.ay, day.az,
          sleepOnsetSec: _on, sleepOffsetSec: _off);
      live.steps.sync(day.ts, day.step, modulus: 65536);
      final pieces = _foldInPieces(day, _chunks(math.Random(9), day.length),
          on: _on, off: _off);
      expect(pieces, encodeDayResumeState(live));
    });

    test('a resumed summary reads like the batch one and folds only the tail', () {
      final day = _synthDay(start: 1760000000, seconds: 12000);
      const cut = 7000;
      final base = _foldInPieces(
        _Day(day.ts.sublist(0, cut), day.hr.sublist(0, cut), day.ax.sublist(0, cut),
            day.ay.sublist(0, cut), day.az.sublist(0, cut), day.step.sublist(0, cut)),
        [cut],
        on: _on,
        off: _off,
      );
      final resumed = decodeDayResumeState(base)!;
      // The pass hands the summaries the whole day, as it always did: the
      // fingerprint of the folded prefix vouches for it and only the tail folds.
      resumed.hrPipeline.sync(day.ts, day.hr,
          sleepOnsetSec: _on, sleepOffsetSec: _off, age: 35);
      resumed.motion.sync(day.ts, day.ax, day.ay, day.az,
          sleepOnsetSec: _on, sleepOffsetSec: _off);
      resumed.steps.sync(day.ts, day.step, modulus: 65536);
      expect(resumed.hrPipeline.processedSamples, day.length - cut);
      expect(resumed.motion.processedSamples, day.length - cut);
      expect(resumed.steps.processedSamples, day.length - cut);

      final batch = DayHrSummary()
        ..sync(day.ts, day.hr, sleepOnsetSec: _on, sleepOffsetSec: _off, age: 35);
      expect(resumed.hrPipeline.hrStats(), batch.hrStats());
      expect(resumed.hrPipeline.wakeMinutes().keys, batch.wakeMinutes().keys);
      expect(resumed.hrPipeline.wakeMinutes().hr, batch.wakeMinutes().hr);
      expect(resumed.hrPipeline.wakeHr, batch.wakeHr);
      final bm = DayMotionSummary()
        ..sync(day.ts, day.ax, day.ay, day.az,
            sleepOnsetSec: _on, sleepOffsetSec: _off);
      expect(resumed.motion.activeMinutes(), bm.activeMinutes());
      expect(resumed.motion.activityCurve(), bm.activityCurve());
      expect(resumed.motion.wearRuns(), bm.wearRuns());
    });

    test('a changed earlier sample is caught by the prefix fingerprint', () {
      final day = _synthDay(start: 1760000000, seconds: 6000);
      final resumed = decodeDayResumeState(encodeDayResumeState(_foldAll(
        _Day(day.ts.sublist(0, 4000), day.hr.sublist(0, 4000), day.ax.sublist(0, 4000),
            day.ay.sublist(0, 4000), day.az.sublist(0, 4000), day.step.sublist(0, 4000)),
      )))!;
      final changed = List<int>.of(day.hr)..[1234] += 1;
      resumed.hrPipeline.sync(day.ts, changed, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      expect(resumed.hrPipeline.processedSamples, day.length,
          reason: 'rebuilt from the first sample, not appended to');
      final oracle = DayHrSummary()
        ..sync(day.ts, changed, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      expect(_bytes(resumed.hrPipeline.write), _bytes(oracle.write));
    });

    test('a different sleep window or age refuses the append', () {
      final day = _synthDay(start: 1760000000, seconds: 3000);
      final blob = _foldInPieces(day, [3000], on: _on, off: _off);
      Uint8List? more({int on = _on, int off = _off, int? age = 35, int? mod = 65536}) =>
          foldDayCheckpoint(
            base: blob,
            alreadyFolded: 3000,
            ts: [day.ts.last + 1],
            hr: [70],
            ax: [0.0],
            ay: [0.0],
            az: [1.0],
            stepCounter: [5],
            sleepOnsetSec: on,
            sleepOffsetSec: off,
            age: age,
            stepModulus: mod,
          );
      expect(more(), isNotNull);
      expect(more(on: _on + 1), isNull);
      expect(more(off: _off + 1), isNull);
      expect(more(age: 36), isNull);
      expect(more(mod: null), isNull);
      expect(
        foldDayCheckpoint(
          base: blob,
          alreadyFolded: 2999,
          ts: const [],
          hr: const [],
          ax: const [],
          ay: const [],
          az: const [],
          stepCounter: const [],
          sleepOnsetSec: _on,
          sleepOffsetSec: _off,
          age: 35,
          stepModulus: 65536,
        ),
        isNull,
        reason: 'the blob folded 3000 seconds, not 2999',
      );
    });
  });

  group('step counter fold', () {
    test('a day folded in pieces credits what hardwareStepsFromCounter credits',
        () {
      for (final seed in [1, 2, 3]) {
        final day = _synthDay(start: 1760000000, seconds: 9000, seed: seed);
        final want = hardwareStepsFromCounter(_substrate(day),
            cumulativeCounterModulus: 65536);
        expect(want, isNotNull);
        final blob = _foldInPieces(day, _chunks(math.Random(seed), day.length));
        expect(decodeDayResumeState(blob)!.steps.steps, want, reason: 'seed $seed');
      }
    });

    test('a counter reset on a piece seam drops only the unreadable delta', () {
      // 100 seconds of a healthy counter, a reset to 0 across the seam, 100 more.
      final ts = [for (var i = 0; i < 200; i++) 1760000000 + i];
      final step = [
        for (var i = 0; i < 100; i++) 20000 + i,
        for (var i = 0; i < 100; i++) i,
      ];
      final day = _Day(ts, List.filled(200, 70), List.filled(200, .1),
          List.filled(200, .1), List.filled(200, 1.0), step);
      final want =
          hardwareStepsFromCounter(_substrate(day), cumulativeCounterModulus: 65536);
      expect(want, 99 + 99, reason: 'the reset delta (20099 -> 0) is dropped');
      for (final seam in [99, 100, 101]) {
        final blob = _foldInPieces(day, [seam, 200 - seam]);
        expect(decodeDayResumeState(blob)!.steps.steps, want, reason: 'seam $seam');
      }
    });

    test('no counter means null, never 0; no modulus means null', () {
      final day = _synthDay(start: 1760000000, seconds: 2000, counter: false);
      expect(
          decodeDayResumeState(_foldInPieces(day, [700, 1300]))!.steps.steps, isNull);
      final withCounter = _synthDay(start: 1760000000, seconds: 2000);
      expect(
          decodeDayResumeState(
                  _foldInPieces(withCounter, [700, 1300], modulus: null))!
              .steps
              .steps,
          isNull);
    });
  });

  group('DST days', () {
    // The folds see epoch seconds only; the 23 h and 25 h days differ in length,
    // and a sleep window may straddle the clock change. The checkpoint
    // boundary is a multiple of 900 s of epoch, never of local time.
    for (final hours in [23, 25]) {
      test('a $hours h day folds the same in pieces', () {
        final seconds = hours * 3600;
        final start = 1773000000 - (1773000000 % kRevBucketSec);
        final ts = [for (var i = 0; i < seconds; i += 5) start + i];
        final n = ts.length;
        final rnd = math.Random(hours);
        final day = _Day(
          ts,
          [for (var i = 0; i < n; i++) 55 + rnd.nextInt(60)],
          [for (var i = 0; i < n; i++) .2 * math.sin(i * .3)],
          [for (var i = 0; i < n; i++) .1 * math.cos(i * .2)],
          List.filled(n, 1.0),
          List.filled(n, -1),
        );
        final on = start + 2 * 3600, off = start + 9 * 3600;
        final once = encodeDayResumeState(_foldAll(day, on: on, off: off));
        final pieces = _foldInPieces(
            day, _chunks(math.Random(hours), n), on: on, off: off);
        expect(pieces, once);
      });
    }

    test('the context signature moves when the clock changed inside the day', () {
      String sig(int end, int offEnd) => dayContextSig(
            profileSig: 'p',
            priorityKey: 'k',
            deviceFamily: 'gen4',
            dayStartSec: 1773000000,
            dayEndSec: end,
            tzOffsetAtStartMin: -300,
            tzOffsetAtEndMin: offEnd,
            sleepOnsetSec: 0,
            sleepOffsetSec: 0,
            sleepSource: 'auto',
            dynFloorG: null,
          );
      expect(sig(1773000000 + 86400, -300), isNot(sig(1773000000 + 82800, -240)));
      expect(sig(1773000000 + 86400, -300), isNot(sig(1773000000 + 90000, -360)));
    });
  });

  // ── engine layer ──────────────────────────────────────────────────────────

  group('engine resume', () {
    const profile = Profile(
      ageYears: 35,
      weightKg: 75,
      heightCm: 178,
      sex: 'male',
      restingHrManual: 54,
    );
    const rowsFirst = 2400; // 40 min: the closed 15-minute boundary is 30 min
    const rowsAll = 4200; // 70 min: the boundary is 60 min

    late int start;
    late String day;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'day_checkpoint_test.db';
    });

    Future<void> wipe() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    }

    setUp(() async {
      await wipe();
      // Yesterday from 08:00 (a bucket boundary): pending, never finalized,
      // whatever time of day the test runs.
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day - 1);
      day = dayLabelOf(midnight);
      start = midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
    });
    tearDownAll(wipe);

    /// One second of the day as the band would have stored it, with a strap
    /// reboot (the counter restarts) 20 minutes in.
    Future<void> rows(int from, int to, {int base = 0, int hrAdd = 0}) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      for (var i = from; i < to; i++) {
        final ts = base == 0 ? start + i : base + i;
        final counter = i < 1200 ? i + 1 : i - 1200 + 5;
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_onehz '
          '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
          "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, ?, ?, ?, ?, ?, 1, 1, 3000, 'gen4')",
          [
            ts * 1000,
            ts,
            counter,
            70 + (i ~/ 60) % 50 + i % 3 + hrAdd,
            .2 * math.sin(i * .27),
            .1 * math.cos(i * .17),
            1 + .03 * math.sin(i * .09),
          ],
        );
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_rr '
          '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
          "VALUES ('', ?, ?, 0, ?, ?)",
          [ts * 1000, ts, ts * 1000, 800 + (i % 7) * 9],
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

    Future<DayCheckpoint?> checkpoint() => LocalDb.dayCheckpoint(day, kAlgoVersion);

    /// A full pass over what the database holds now, which rewrites the day and
    /// its checkpoint from the first second: the oracle.
    Future<void> oracle() => DerivationEngine().run(profile, force: true);

    List<String> ckptLines(List<String> log) =>
        [
          for (final l in log)
            if (l.contains('[perf] checkpoint $day'))
              l.substring(l.indexOf('[perf] checkpoint')),
        ];

    test('a headless wake resumes from the checkpoint and stores what a full pass does',
        () async {
      await rows(0, rowsFirst);
      final first = <String>[];
      await DerivationEngine(log: first.add).run(profile);
      expect(ckptLines(first), ['[perf] checkpoint $day full none']);
      final cp1 = (await checkpoint())!;
      expect(cp1.cpRecTs, start + 1800, reason: 'newest closed 15-minute boundary');
      expect(cp1.fmt, kDayCheckpointFmt);
      final s1 = decodeDayResumeState(cp1.state)!;
      expect(s1.folded, 1800);
      final revs = decodeRevVec(cp1.revVec)!;
      expect(revs.keys.reduce(math.min), start ~/ kRevBucketSec);
      expect(revs.keys.reduce(math.max), (start + 1800) ~/ kRevBucketSec - 1,
          reason: 'closed buckets only');

      await rows(rowsFirst, rowsAll);
      final log = <String>[];
      final headless = newHeadlessDerivationEngine(log.add);
      await headless.run(profile);
      expect(ckptLines(log), ['[perf] checkpoint $day resume folded=1800']);
      final state = headless.debugCalculationState(day)!;
      // Two heart-rate summaries and one orientation summary, each folding only
      // the seconds after the checkpoint; a pass without it folds all of them.
      expect(state.hrSamples, 2 * (rowsAll - 1800));
      expect(state.orientationSamples, rowsAll - 1800);
      expect(state.stepSamples, rowsAll - 1800);
      final cp2 = (await checkpoint())!;
      expect(cp2.cpRecTs, start + 3600);
      expect(decodeDayResumeState(cp2.state)!.folded, 3600);

      final resumed = await stored();
      await oracle();
      expect(await stored(), equals(resumed),
          reason: 'resuming changes no stored figure');
      final cp3 = (await checkpoint())!;
      expect(cp3.cpRecTs, cp2.cpRecTs);
      expect(cp3.state, cp2.state,
          reason: 'resumed-then-advanced is byte-identical to folded at once');
      expect(cp3.revVec, cp2.revVec);
    });

    test('a pass that finds no newer closed boundary leaves the checkpoint alone',
        () async {
      await rows(0, rowsFirst);
      await DerivationEngine().run(profile);
      final cp1 = (await checkpoint())!;
      await rows(rowsFirst, 2700); // still inside the same open bucket
      await DerivationEngine().run(profile);
      final cp2 = (await checkpoint())!;
      expect(cp2.cpRecTs, cp1.cpRecTs);
      expect(cp2.computedAt, cp1.computedAt, reason: 'not rewritten');
    });

    test('a day with no closed 15-minute bucket gets no checkpoint', () async {
      await rows(0, 500);
      await DerivationEngine().run(profile);
      expect(await LocalDb.dayResult(day), isNotNull);
      expect(await checkpoint(), isNull);
    });

    group('every invalidation row falls back to a full pass', () {
      /// Seeds, derives (writing a checkpoint), changes the world with
      /// [change], appends, derives in a fresh engine, and returns that
      /// engine's checkpoint lines; the stored day must equal a full pass.
      Future<List<String>> scenario(
        Future<void> Function() change, {
        Profile? profileAfter,
        bool appendFirst = true,
      }) async {
        await rows(0, rowsFirst);
        await DerivationEngine().run(profile);
        expect(await checkpoint(), isNotNull);
        await change();
        if (appendFirst) await rows(rowsFirst, rowsAll);
        final log = <String>[];
        await DerivationEngine(log: log.add).run(profileAfter ?? profile,
            heavy: true);
        final got = await stored();
        await DerivationEngine().run(profileAfter ?? profile, force: true);
        expect(await stored(), equals(got),
            reason: 'the pass after the change stores what a full pass stores');
        return ckptLines(log);
      }

      test('an earlier second replaced', () async {
        final lines = await scenario(() => rows(100, 101, hrAdd: 9));
        expect(lines.single, contains('full revised:'));
      });

      test('a late arrival into an earlier gap', () async {
        await rows(0, 300);
        await rows(360, rowsFirst);
        await DerivationEngine().run(profile);
        expect(await checkpoint(), isNotNull);
        await rows(300, 360); // history that reached the phone later
        await rows(rowsFirst, rowsAll);
        final log = <String>[];
        await DerivationEngine(log: log.add).run(profile, heavy: true);
        expect(ckptLines(log).single, contains('full revised:'));
        final got = await stored();
        await DerivationEngine().run(profile, force: true);
        expect(await stored(), equals(got));
      });

      test('rows evicted, with their beats', () async {
        final lines = await scenario(() async {
          final db = await LocalDb.instance;
          await db.delete('decoded_onehz',
              where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [start, start + 50]);
          await db.delete('decoded_rr',
              where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [start, start + 50]);
        });
        expect(lines.single, matches(RegExp('full (revised|lost):')));
      });

      test('a counter re-keyed (strap reset)', () async {
        final lines = await scenario(() async {
          final db = await LocalDb.instance;
          await db.update('decoded_onehz', {'counter': 99999},
              where: 'rec_ts = ?', whereArgs: [start + 10]);
        });
        expect(lines.single, contains('full revised:'));
      });

      test('a profile change', () async {
        final lines = await scenario(() async {},
            profileAfter: const Profile(
              ageYears: 36,
              weightKg: 75,
              heightCm: 178,
              sex: 'male',
              restingHrManual: 54,
            ));
        expect(lines.single, '[perf] checkpoint $day full context');
      });

      test('a signal priority change', () async {
        final lines = await scenario(() =>
            LocalDb.setSignalPriority(InputSignal.hr1Hz, ['', 'other-strap']));
        expect(lines.single, '[perf] checkpoint $day full context');
      });

      test('a sleep window edit rebuilds instead of resuming', () async {
        final lines = await scenario(() => LocalDb.putSleepOverride(
              dayId: day,
              onsetTs: start - 7 * 3600,
              offsetTs: start - 600,
              source: 'manual',
            ));
        expect(lines, isEmpty, reason: 'a user edit never resumes');
        // ...and the checkpoint it leaves is the one a full pass writes under
        // the new window, so the next ordinary pass can resume from it.
        final cp = (await checkpoint())!;
        expect(decodeDayResumeState(cp.state), isNotNull);
      });

      test('another layout version', () async {
        final lines = await scenario(() async {
          final db = await LocalDb.instance;
          await db.update('day_checkpoint', {'fmt': kDayCheckpointFmt + 1});
        });
        expect(lines.single, '[perf] checkpoint $day full fmt');
      });

      test('another algorithm version', () async {
        final lines = await scenario(() async {
          final db = await LocalDb.instance;
          await db.update('day_checkpoint', {'algo_version': kAlgoVersion - 1});
        });
        expect(lines.single, '[perf] checkpoint $day full none');
      });

      test('a blob this build cannot read', () async {
        final lines = await scenario(() async {
          final cp = (await checkpoint())!;
          await LocalDb.putDayCheckpoint(DayCheckpoint(
            dayId: cp.dayId,
            algoVersion: cp.algoVersion,
            fmt: cp.fmt,
            ctxSig: cp.ctxSig,
            cpRecTs: cp.cpRecTs,
            revVec: cp.revVec,
            state: _withFmt(cp.state, kDayCheckpointFmt + 7),
            nightRef: cp.nightRef,
            computedAt: cp.computedAt,
          ));
        });
        expect(lines.single, '[perf] checkpoint $day full unreadable_state');
      });

      test('a blob that folded a different number of seconds', () async {
        final lines = await scenario(() async {
          final cp = (await checkpoint())!;
          final short = _foldAll(_synthDay(start: start, seconds: 1799));
          await LocalDb.putDayCheckpoint(DayCheckpoint(
            dayId: cp.dayId,
            algoVersion: cp.algoVersion,
            fmt: cp.fmt,
            ctxSig: cp.ctxSig,
            cpRecTs: cp.cpRecTs,
            revVec: cp.revVec,
            state: encodeDayResumeState(short),
            nightRef: cp.nightRef,
            computedAt: cp.computedAt,
          ));
        });
        expect(lines.single, '[perf] checkpoint $day full folded');
      });
    });

    test('a finalized day drops its checkpoint, an unretained one is pruned',
        () async {
      // Three days ago, then data on the day after tomorrow-of-it: the old day
      // finalizes (its end plus 48 h is before the newest data).
      final old = DateTime.fromMillisecondsSinceEpoch(start * 1000)
          .subtract(const Duration(days: 2));
      final oldDay = dayLabelOf(old);
      final oldStart = start - 2 * 86400;
      await rows(0, 2000, base: oldStart);
      await rows(0, 2500);
      final stale = DayCheckpoint(
        dayId: '2001-01-01',
        algoVersion: kAlgoVersion,
        fmt: kDayCheckpointFmt,
        ctxSig: 'x',
        cpRecTs: 900,
        revVec: Uint8List(0),
        state: Uint8List(0),
        nightRef: null,
        computedAt: 1,
      );
      await LocalDb.putDayCheckpoint(stale);
      await DerivationEngine().run(profile, heavy: true);
      expect(await LocalDb.dayCheckpoint(day, kAlgoVersion), isNotNull);
      expect(await LocalDb.dayCheckpoint(oldDay, kAlgoVersion), isNull,
          reason: 'finalized: frozen, never recomputed incrementally');
      final row = (await LocalDb.dayResult(oldDay))!;
      expect(row['finalized'], 1, reason: 'the fixture really finalized the old day');
      expect(await LocalDb.dayCheckpoint('2001-01-01', kAlgoVersion), isNull,
          reason: 'older than the retention');
    });
  });
}
