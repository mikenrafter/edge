// RED -> GREEN: a WARM pass may stream the day's RR from the stored checkpoint
// only when that checkpoint passes the SAME gate a cold resume passes: the day
// context (profile, ownership/priority, family, tz offsets, source) AND the
// folded-row count. The warm probe used to compare the checkpoint's context
// signature with itself and never checked `folded`, so after
//
//  (a) an ownership change over the folded range (a second device's beats
//      becoming the owner; the band's own rows and revisions did not move),
//  (b) the day context moving (a timezone offset change is a different
//      `ctxSig`; the process zone cannot be changed mid-test, so the stored
//      signature is the one that is moved), or
//  (c) a checkpoint that folded another number of seconds than the day holds
//      before its cursor (dayStart moved),
//
// a warm pass streamed from a checkpoint folded under the old context, and
// `_refreshCheckpoint` (which does judge the context) refused to extend it, so
// the stale checkpoint was never replaced: every later warm pass streamed from
// it again and a finalizing pass froze the result.
//
// Each case: the stored day equals a cold batch over the same rows, and the
// checkpoint was REWRITTEN (the context signature it carries is the cold
// pass's, its cursor is as far).
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
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

const _ring = 'ring-TEST-0001';
const _steps = [3 * 3600, 3 * 3600 + 1200, 3 * 3600 + 2400];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int start;
  late String day;
  late Beats beats;
  late Accel accel;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'day_rr_warm_gate_test.db';
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

  Future<DayCheckpoint?> checkpoint() =>
      LocalDb.dayCheckpoint(day, kAlgoVersion);

  /// The second device: a ring whose beats (a different, steady rhythm) cover
  /// the band's first half hour, written up front so that nothing the band
  /// owns moves when it later becomes the owner.
  Future<void> seedRing() async {
    final db = await LocalDb.instance;
    final batch = db.batch();
    for (var s = start + 600; s < start + 1800; s++) {
      batch.insert(
          'decoded_rr',
          {
            'device_id': _ring,
            'ts_ms': s * 1000,
            'rec_ts': s,
            'beat_index': 0,
            'rr_ts_ms': s * 1000,
            'rr_ms': 700 + (s % 5) * 11,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final (dev, from, to) in [
      ('', start, start + 4 * 3600 + 60),
      (_ring, start + 600, start + 1800),
    ]) {
      batch.insert(
          'device_coverage',
          {
            'device_id': dev,
            'signal': InputSignal.rrIntervals.name,
            'start_ts': from,
            'end_ts': to,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await LocalDb.setSignalPriority(InputSignal.rrIntervals, ['', _ring]);
  }

  /// After the warm pass: what is stored and the checkpoint, then the cold
  /// batch over the same rows, and the two compared.
  Future<void> expectWarmIsBatchAndRewritten(String why) async {
    final warm = await stored();
    final warmCp = (await checkpoint())!;
    await DerivationEngine().run(_profile, force: true);
    final cold = await stored();
    final coldCp = (await checkpoint())!;
    expect(warm, equals(cold), reason: 'whole stored day: $why');
    expect(warmCp.ctxSig, coldCp.ctxSig,
        reason: 'the checkpoint carries the current context: $why');
    expect(warmCp.cpRecTs, coldCp.cpRecTs,
        reason: 'and was extended to the same boundary: $why');
  }

  test('(a) ownership of the folded range changes under a warm engine',
      () async {
    await seedRing();
    final warm = DerivationEngine();
    await rows(0, _steps[0]);
    await warm.run(_profile);
    await rows(_steps[0], _steps[1]);
    await warm.run(_profile);
    expect(await checkpoint(), isNotNull, reason: 'fixture: a checkpoint');
    // The ring now outranks the band for beats: its rhythm owns [10 min,
    // 30 min), inside what the checkpoint folded. No band row moved.
    await LocalDb.setSignalPriority(InputSignal.rrIntervals, [_ring, '']);
    await rows(_steps[1], _steps[2]);
    await warm.run(_profile);
    await expectWarmIsBatchAndRewritten('ownership moved');
  });

  test('(b) the day context signature moves under a warm engine', () async {
    final warm = DerivationEngine();
    await rows(0, _steps[0]);
    await warm.run(_profile);
    await rows(_steps[0], _steps[1]);
    await warm.run(_profile);
    final cp = (await checkpoint())!;
    await LocalDb.putDayCheckpoint(DayCheckpoint(
      dayId: cp.dayId,
      algoVersion: cp.algoVersion,
      fmt: cp.fmt,
      ctxSig: 'a different zone offset',
      cpRecTs: cp.cpRecTs,
      revVec: cp.revVec,
      state: cp.state,
      nightRef: cp.nightRef,
      computedAt: cp.computedAt,
    ));
    await rows(_steps[1], _steps[2]);
    await warm.run(_profile);
    await expectWarmIsBatchAndRewritten('context moved');
  });

  test('(c) the checkpoint folded another number of seconds than the day holds',
      () async {
    final warm = DerivationEngine();
    await rows(0, _steps[0]);
    await warm.run(_profile);
    await rows(_steps[0], _steps[1]);
    await warm.run(_profile);
    final cp = (await checkpoint())!;
    // A valid blob that folded 1000 seconds only (its beats and curves are the
    // first 1000 seconds'), under the real context and cursor.
    const k = 1000;
    final ts = accel.tsSec.where((t) => t < accel.tsSec.first + k).toList();
    final short = foldDayCheckpoint(
      base: null,
      alreadyFolded: 0,
      ts: ts,
      hr: List.filled(ts.length, 0),
      ax: accel.ax.sublist(0, ts.length),
      ay: accel.ay.sublist(0, ts.length),
      az: accel.az.sublist(0, ts.length),
      stepCounter: List.filled(ts.length, -1),
      age: _profile.ageYears,
      stepModulus: null,
    );
    expect(short, isNotNull, reason: 'fixture: a foldable short blob');
    await LocalDb.putDayCheckpoint(DayCheckpoint(
      dayId: cp.dayId,
      algoVersion: cp.algoVersion,
      fmt: cp.fmt,
      ctxSig: cp.ctxSig,
      cpRecTs: cp.cpRecTs,
      revVec: cp.revVec,
      state: Uint8List.fromList(short!),
      nightRef: cp.nightRef,
      computedAt: cp.computedAt,
    ));
    await rows(_steps[1], _steps[2]);
    await warm.run(_profile);
    final warmDay = await stored();
    final after = await checkpoint();
    if (after != null) {
      // Never left holding the short blob under the full cursor.
      final st = decodeDayResumeState(after.state);
      expect(st, isNotNull);
      expect(st!.folded, isNot(ts.length),
          reason: 'the mismatched blob was replaced or dropped');
    }
    await DerivationEngine().run(_profile, force: true);
    expect(warmDay, equals(await stored()), reason: 'whole stored day');
  });

  test('the per-pass probe does not decode the checkpoint on the engine isolate',
      () {
    // Every warm pass probes; a decode there is O(blob) on the UI isolate
    // (AGENTS 3.10). The probe reads the header, the worker decodes.
    final src = File('lib/compute/derivation_engine.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final a = src.indexOf('Future<DayRrResume?> _probeRrResume(');
    final b = src.indexOf('Who owns each anchor signal', a);
    final probe = src.substring(a, b < 0 ? a + 2000 : b);
    expect(a, isNonNegative);
    expect(probe, contains('peekDayResumeFolded'));
    expect(probe, isNot(contains('decodeDayResumeState')));
  });
}
