// When a day checkpoint may be resumed from. The decision is pure; the
// invalidation cases below run against the real `input_rev` triggers, because
// "an earlier row changed" is exactly what those triggers report.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _v = 101;
const _sig = 'ctx';
// A bucket-aligned day start well inside one hour grid.
const _t0 = 1760000100 - (1760000100 % 900); // multiple of 900

Future<void> _onehz(int ts, {int hr = 60, int counter = 0}) async {
  final db = await LocalDb.instance;
  await db.execute(
    'INSERT OR REPLACE INTO decoded_onehz '
    '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, device_family) '
    "VALUES ('', ?, ?, ?, ?, 0, 0, 1, 'gen4')",
    [ts * 1000, ts, counter == 0 ? ts : counter, hr],
  );
}

Future<void> _rr(int ts, {int beat = 0, int ms = 900}) async {
  final db = await LocalDb.instance;
  await db.execute(
    'INSERT OR REPLACE INTO decoded_rr '
    '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
    "VALUES ('', ?, ?, ?, ?, ?)",
    [ts * 1000, ts, beat, ts * 1000, ms],
  );
}

/// A checkpoint folded through `cpRecTs`, written the way the engine will.
Future<DayCheckpoint> _checkpoint(int cpRecTs, {String ctx = _sig}) async {
  final revs = await LocalDb.inputRevisions(_t0 ~/ 900, cpRecTs ~/ 900);
  return DayCheckpoint(
    dayId: 'd',
    algoVersion: _v,
    fmt: kDayCheckpointFmt,
    ctxSig: ctx,
    cpRecTs: cpRecTs,
    revVec: encodeRevVec(revs),
    state: Uint8List(0),
    nightRef: null,
    computedAt: 1,
  );
}

Future<ResumeDecision> _decide(DayCheckpoint? cp,
    {String ctx = _sig, int algo = _v}) async {
  final live = cp == null
      ? <int, int>{}
      : await LocalDb.inputRevisions(_t0 ~/ 900, cp.cpRecTs ~/ 900);
  return decideResume(cp: cp, algoVersion: algo, ctxSig: ctx, liveRevs: live);
}

void main() {
  group('revision vector packing', () {
    test('round-trips in bucket order, whatever the insertion order', () {
      final out = decodeRevVec(encodeRevVec({9: 3, 2: 7, 5: 1}))!;
      expect(out, {2: 7, 5: 1, 9: 3});
      expect(out.keys.toList(), [2, 5, 9]);
      expect(encodeRevVec({9: 3, 2: 7}), encodeRevVec({2: 7, 9: 3}));
    });
    test('an empty vector and a torn blob', () {
      expect(decodeRevVec(encodeRevVec(const {})), isEmpty);
      expect(decodeRevVec(Uint8List(7)), isNull);
    });
  });

  group('day context signature', () {
    String sig({
      String profile = 'p',
      String priority = 'a>b',
      String? family = 'gen4',
      int start = 1000,
      int end = 1000 + 86400,
      int offStart = 0,
      int offEnd = 0,
      int onset = 10,
      int offset = 20,
      String? source = 'auto',
      double? floor = .03,
    }) =>
        dayContextSig(
          profileSig: profile,
          priorityKey: priority,
          deviceFamily: family,
          dayStartSec: start,
          dayEndSec: end,
          tzOffsetAtStartMin: offStart,
          tzOffsetAtEndMin: offEnd,
          sleepOnsetSec: onset,
          sleepOffsetSec: offset,
          sleepSource: source,
          dynFloorG: floor,
        );

    test('equal parts, equal signature; any part moves it', () {
      final base = sig();
      expect(sig(), base);
      for (final other in [
        sig(profile: 'q'),
        sig(priority: 'b>a'),
        sig(family: 'gen5'),
        sig(family: null),
        sig(start: 1001),
        sig(end: 1000 + 86400 + 1),
        sig(offStart: 60),
        sig(offEnd: 60),
        sig(onset: 11),
        sig(offset: 21),
        sig(source: 'manual'),
        sig(source: null),
        sig(floor: .04),
        sig(floor: null),
      ]) {
        expect(other, isNot(base));
      }
    });

    test('a DST day (23 h and 25 h) is not the 24 h day', () {
      final normal = sig();
      expect(sig(end: 1000 + 23 * 3600, offEnd: 60), isNot(normal));
      expect(sig(end: 1000 + 25 * 3600, offEnd: -60), isNot(normal));
      expect(sig(end: 1000 + 86400, offEnd: 60), isNot(normal),
          reason: 'same epochs but the clock moved inside the day');
    });
  });

  group('decideResume against the real input_rev triggers', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });
    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'day_checkpoint_policy_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.instance;
      // Four closed hours of data, a beat in each, and the open bucket after.
      for (var b = 0; b < 4; b++) {
        for (var i = 0; i < 5; i++) {
          await _onehz(_t0 + b * 900 + i * 10, hr: 60 + i);
        }
        await _rr(_t0 + b * 900 + 3);
      }
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    final cpAt = _t0 + 4 * 900;

    test('untouched closed buckets resume, appends after it do not matter',
        () async {
      final cp = await _checkpoint(cpAt);
      expect((await _decide(cp)).resume, isTrue);
      for (var i = 0; i < 20; i++) {
        await _onehz(cpAt + i, hr: 70);
        await _rr(cpAt + i, beat: 1);
      }
      expect((await _decide(cp)).resume, isTrue,
          reason: 'the open bucket is outside the checkpoint');
    });

    test('an earlier rec_ts replaced in place (INSERT OR REPLACE)', () async {
      final cp = await _checkpoint(cpAt);
      await _onehz(_t0 + 1 * 900, hr: 61); // same second, same hr: value-identical
      final d = await _decide(cp);
      expect(d.resume, isFalse);
      expect(d.reason, startsWith('revised:'));
    });

    test('an earlier row inserted into an empty bucket (late history)', () async {
      await (await LocalDb.instance)
          .delete('decoded_onehz', where: 'rec_ts >= ? AND rec_ts < ?',
              whereArgs: [_t0 + 900, _t0 + 1800]);
      await (await LocalDb.instance).delete('decoded_rr',
          where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [_t0 + 900, _t0 + 1800]);
      final cp = await _checkpoint(cpAt);
      expect((await _decide(cp)).resume, isTrue);
      await _onehz(_t0 + 900 + 5);
      expect((await _decide(cp)).resume, isFalse);
    });

    test('an earlier row evicted (delete)', () async {
      final cp = await _checkpoint(cpAt);
      await (await LocalDb.instance)
          .delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [_t0 + 10]);
      expect((await _decide(cp)).resume, isFalse);
    });

    test('an RR-only change in an earlier bucket', () async {
      final cp = await _checkpoint(cpAt);
      await _rr(_t0 + 2 * 900 + 3, ms: 905);
      expect((await _decide(cp)).resume, isFalse);
    });

    test('a counter reset: the same seconds re-keyed to a new counter', () async {
      final cp = await _checkpoint(cpAt);
      await _onehz(_t0 + 2 * 900 + 10, hr: 62, counter: 9);
      expect((await _decide(cp)).resume, isFalse);
    });

    test('a whole earlier bucket pruned away', () async {
      final cp = await _checkpoint(cpAt);
      await (await LocalDb.instance)
          .delete('decoded_onehz', where: 'rec_ts < ?', whereArgs: [_t0 + 900]);
      await (await LocalDb.instance)
          .delete('decoded_rr', where: 'rec_ts < ?', whereArgs: [_t0 + 900]);
      expect((await _decide(cp)).resume, isFalse);
    });

    test('context, algo version and layout each force a full pass', () async {
      final cp = await _checkpoint(cpAt);
      expect((await _decide(cp, ctx: 'other')).reason, 'context');
      expect((await _decide(cp, algo: _v + 1)).reason, 'algo');
      expect((await _decide(null)).reason, 'none');
      final fmt2 = DayCheckpoint(
        dayId: cp.dayId, algoVersion: cp.algoVersion, fmt: cp.fmt + 1,
        ctxSig: cp.ctxSig, cpRecTs: cp.cpRecTs, revVec: cp.revVec,
        state: cp.state, nightRef: null, computedAt: 1,
      );
      expect((await _decide(fmt2)).reason, 'fmt');
    });

    test('a checkpoint that is not on a bucket boundary is never resumed',
        () async {
      final cp = await _checkpoint(cpAt + 1);
      expect((await _decide(cp)).reason, 'unaligned');
    });

    test('a torn revision blob is never resumed', () async {
      final cp = await _checkpoint(cpAt);
      final torn = DayCheckpoint(
        dayId: cp.dayId, algoVersion: cp.algoVersion, fmt: cp.fmt,
        ctxSig: cp.ctxSig, cpRecTs: cp.cpRecTs, revVec: Uint8List(5),
        state: cp.state, nightRef: null, computedAt: 1,
      );
      expect((await _decide(torn)).reason, 'unreadable');
    });
  });
}
