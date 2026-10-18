// Review follow-ups to "Not sleep" / "Set the times myself" blanking the night.
// "I'd rather absence than wrong data": a blanked night shows nothing and is in
// no score or baseline afterwards.
//
//  A. The blank must not depend on the global data watermark. With NO decoded
//     rows left at all (everything pruned, only `day_result` remains), both
//     `run()` and `runDays()` returned "no decoded data" before the blank was
//     ever written, and the app reported success.
//  B. `putDayResult` only deleted the blanked keys when the row was not
//     `partial`; a blank that persists as partial (second half failed, or a
//     cross-version carry) left the old rmssd/rhr/readiness rows feeding
//     baselines. And `carryForwardDetail` merged the previous night's scalars,
//     series and sleep periods back into a blank bundle.
//  C. Nap detection must not pick a rejected / user-set main window back up
//     as a nap (shown as "Asleep" and credited to sleep need), while an
//     unrelated daytime nap survives.
//  D. A night already folded into the rolling `sleep_user_profile` stays in the
//     staging thresholds after the user rejects it, unless the edit rebuilds
//     the profile without it.
//
// Real LocalDb + real DerivationEngine. Fixed local-time fixtures.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/sleep_blank.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _d2 = '2025-09-05';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

late Database _db;

Future<void> _freshDb() async {
  await LocalDb.close();
  LocalDb.dbName = 'sleep_blank_review_test.db';
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  _db = await LocalDb.instance;
}

Future<void> _seed() async {
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

Future<void> _derive(String day) =>
    DerivationEngine().runDays(const Profile(), {day}, force: true);

Future<void> _override(String day, int onset, int offset, String source) =>
    LocalDb.putSleepOverride(
      dayId: day,
      onsetTs: onset,
      offsetTs: offset,
      source: source,
    );

Future<void> _realNight(String day, {required int prevDay}) async {
  await _override(
    day,
    _sec(2025, 9, prevDay, 23, 30),
    _sec(2025, 9, prevDay + 1, 6, 30),
    'confirmed',
  );
  await _derive(day);
}

Future<Map<String, dynamic>> _bundle(String day) async {
  final r = await LocalDb.dayResult(day);
  return jsonDecode(r!['payload_json'] as String) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _scalars(String day) async =>
    ((await _bundle(day))['scalars'] as Map).cast<String, dynamic>();

Future<Map<String, double?>> _series(String day) async => {
      for (final r in await _db
          .query('metric_series', where: 'date = ?', whereArgs: [day]))
        r['key'] as String: (r['value'] as num?)?.toDouble(),
    };

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await _freshDb();
    await _seed();
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // ── A ────────────────────────────────────────────────────────────────────
  group('A. blanking does not need any decoded data', () {
    Future<void> pruneEverything() async {
      await _realNight(_d2, prevDay: 4);
      await _db.delete('decoded_onehz');
      await _db.delete('sleep_session_candidates');
      expect(await LocalDb.lastDecodedRecTs(), isNull,
          reason: 'fixture: the data watermark is gone');
    }

    Future<void> expectBlank() async {
      expect((await _scalars(_d2))['tst_min'], isNull);
      expect((await _series(_d2)).containsKey('tst_min'), isFalse);
      expect((await _series(_d2)).containsKey('rhr'), isFalse);
      expect((await LocalDb.dayResult(_d2))!['rhr'], isNull);
      expect((await _bundle(_d2))['date'], _d2, reason: 'rest of day kept');
    }

    test('rederiveAfterSleepEdit (Not sleep) with no decoded rows at all',
        () async {
      await pruneEverything();
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'rejected');
      final engine = DerivationEngine();
      await engine.rederiveAfterSleepEdit(const Profile(), _d2);
      expect(engine.snapshot()['last_error'], isNull);
      await expectBlank();
    });

    test('runDays (manual window) with no decoded rows at all', () async {
      await pruneEverything();
      await _override(_d2, _sec(2025, 9, 5, 12, 30), _sec(2025, 9, 5, 15, 30),
          'manual');
      await DerivationEngine().runDays(const Profile(), {_d2}, force: true);
      await expectBlank();
    });

    test('run() with no decoded rows at all', () async {
      await pruneEverything();
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'rejected');
      await DerivationEngine().run(const Profile(), force: true);
      await expectBlank();
    });

    test('a pass with no decoded rows and no blanking override still does '
        'nothing', () async {
      await pruneEverything();
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'confirmed');
      expect(
          await DerivationEngine()
              .runDays(const Profile(), {_d2}, force: true),
          0);
      expect((await _scalars(_d2))['tst_min'], 420);
    });
  });

  // ── B ────────────────────────────────────────────────────────────────────
  group('B. a partial blank still removes the night', () {
    test('putDayResult(partial: true, blankKeys) deletes the old rows',
        () async {
      await _realNight(_d2, prevDay: 4);
      expect((await _series(_d2))['tst_min'], 420);
      final row = (await LocalDb.dayResult(_d2))!;
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: kAlgoVersion,
        payloadJson: row['payload_json'] as String,
        windowJson: row['window_json'] as String,
        partial: true,
        series: {'rhr': null, 'rmssd': null, 'strain': 3.0},
        blankKeys: kSleepDerivedMetricKeys,
      );
      final s = await _series(_d2);
      for (final k in kSleepDerivedMetricKeys) {
        expect(s.containsKey(k), isFalse, reason: k);
      }
    });

    test('carryForwardDetail into a blanked bundle brings back no night',
        () {
      final prev = <String, dynamic>{
        'date': _d2,
        'sleep_periods': {
          'periods': [
            {'is_main': true, 'duration_min': 420},
            {'is_main': false, 'duration_min': 30},
          ],
          'total_asleep_min': 450,
        },
        'wrist_orientation': {'dominant': 'supine'},
        'naps': {'value': [], 'count': 0},
        'series': {
          'hypnogram': [
            {'start': 1}
          ],
          'hr_day': [1],
        },
        'scalars': {
          'rhr': 55.0,
          'rmssd': 40.0,
          'readiness': 71.0,
          'tst_min': 420.0,
          'strain': 9.0,
          'steps': 4000.0,
        },
      };
      // What the first half writes for a blanked night: explicit nulls for
      // some keys, silence on others.
      final next = <String, dynamic>{
        'date': _d2,
        'flags': ['SLEEP_REJECTED'],
        'series': {'hypnogram': []},
        'scalars': <String, dynamic>{'rhr': null, 'tst_min': null, 'strain': null},
      };
      final absent = (jsonDecode(jsonEncode(next)) as Map).cast<String, dynamic>();
      DerivationEngine.carryForwardDetail(prev, next, blankSource: 'rejected');
      // Absent from `next`, so they were carried; but not the night's.
      final sc = (next['scalars'] as Map);
      for (final k in kSleepDerivedMetricKeys) {
        expect(sc[k], isNull, reason: 'scalar $k must stay blank');
      }
      expect(sc['steps'], 4000.0, reason: 'daytime detail is still carried');
      expect((next['series'] as Map)['hypnogram'], isEmpty);
      expect((next['series'] as Map)['hr_day'], [1]);
      final periods = (next['sleep_periods'] as Map);
      expect((periods['periods'] as List).map((e) => (e as Map)['is_main']),
          [false],
          reason: 'the nap stays, the main period does not come back');
      expect(periods['total_asleep_min'], isNull);
      expect(next.containsKey('wrist_orientation'), isFalse);
      expect(next['flags'], absent['flags']);
    });
  });

  // ── C ────────────────────────────────────────────────────────────────────
  group('C. a blanked window is not re-detected as a nap', () {
    const midnight = 1750000800;

    /// Awake-moving day with two still, low-HR blocks: [a0,a1) and [b0,b1)
    /// (offsets from midnight).
    Substrate day(List<(int, int)> blocks) {
      const len = 20 * 3600;
      final ts = <int>[];
      final hr = <int>[];
      final ax = <double>[];
      final az = <double>[];
      for (var i = 0; i < len; i++) {
        ts.add(midnight + i);
        final still = blocks.any((b) => i >= b.$1 && i < b.$2);
        hr.add(still ? 56 : 78);
        if (still) {
          ax.add(0.0);
          az.add(1.0);
        } else {
          final rad = (i % 9) * 10.0 * math.pi / 180.0;
          ax.add(math.cos(rad));
          az.add(math.sin(rad));
        }
      }
      return Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: List<double>.filled(len, 0.0),
        az: az,
        spo2Red: List<int>.filled(len, 0),
        spo2Ir: List<int>.filled(len, 0),
        skinTemp: List<int>.filled(len, 0),
        skinContact: List<int>.filled(len, 0),
      );
    }

    const night = (1 * 3600, 5 * 3600); // 01:00-05:00
    const afternoon = (14 * 3600, 14 * 3600 + 50 * 60);

    test('sanity: with no override both stretches are detected', () {
      final bundle = <String, dynamic>{};
      final naps = DerivationEngine.debugAttachNaps(
        bundle,
        <String, dynamic>{},
        day([night, afternoon]),
        0,
        0,
        attributionStartSec: midnight,
        attributionEndSec: midnight + 86400,
      );
      expect(naps, hasLength(2));
    });

    test('the rejected / user-set span is excluded; the afternoon nap stays',
        () {
      final bundle = <String, dynamic>{};
      final sc = <String, dynamic>{};
      final naps = DerivationEngine.debugAttachNaps(
        bundle,
        sc,
        day([night, afternoon]),
        0,
        0,
        attributionStartSec: midnight,
        attributionEndSec: midnight + 86400,
        blanked: [
          [midnight + night.$1 - 600, midnight + night.$2 + 600]
        ],
      );
      expect(naps, hasLength(1));
      final start = (naps!.single['onset_ts'] as num).toInt();
      expect(start, greaterThanOrEqualTo(midnight + afternoon.$1 - 60));
      expect(start, lessThan(midnight + afternoon.$2));
      // Credited minutes are the afternoon's only.
      expect(sc['nap_min'], lessThanOrEqualTo(55));
    });
  });

  group('C (engine). a rejected night yields no nap inside its span', () {
    // An awake, moving 09-05 with a still low-HR stretch at 01:00-05:00 (what
    // the user rejected / set times over) and a separate 14:00-14:50 nap.
    Future<void> seedDay() async {
      await _db.delete('decoded_onehz');
      final b = _db.batch();
      final from = _sec(2025, 9, 5, 0, 0);
      final to = _sec(2025, 9, 6, 0, 0);
      final still1 = [_sec(2025, 9, 5, 1, 0), _sec(2025, 9, 5, 5, 0)];
      final still2 = [_sec(2025, 9, 5, 14, 0), _sec(2025, 9, 5, 14, 50)];
      for (var ts = from; ts < to; ts++) {
        final still = (ts >= still1[0] && ts < still1[1]) ||
            (ts >= still2[0] && ts < still2[1]);
        final rad = ((ts - from) % 9) * 10.0 * math.pi / 180.0;
        b.insert('decoded_onehz', {
          'device_id': '',
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'counter': ts - from,
          'hr': still ? 56 : 78,
          'ax': still ? 0.0 : math.cos(rad),
          'ay': 0.0,
          'az': still ? 1.0 : math.sin(rad),
          'device_family': 'gen4',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    }

    List<int> napStarts(Map<String, dynamic> bundle) => [
          for (final n
              in ((bundle['naps'] as Map?)?['value'] as List?) ?? const [])
            ((n as Map)['start'] as num).toInt(),
        ];

    for (final source in ['rejected', 'manual']) {
      test('$source window: the span is no nap, the afternoon nap stays',
          () async {
        await seedDay();
        await _override(
            _d2, _sec(2025, 9, 4, 23, 0), _sec(2025, 9, 5, 5, 30), source);
        await _derive(_d2);
        final bundle = await _bundle(_d2);
        final starts = napStarts(bundle);
        expect(
            starts.where((t) =>
                t >= _sec(2025, 9, 4, 23, 0) && t < _sec(2025, 9, 5, 5, 30)),
            isEmpty,
            reason: 'a nap inside the blanked window: $starts');
        expect(
            starts.where((t) =>
                t >= _sec(2025, 9, 5, 13, 50) && t < _sec(2025, 9, 5, 14, 50)),
            hasLength(1),
            reason: 'the unrelated afternoon nap survives: $starts');
        final sc = await _scalars(_d2);
        expect(sc['nap_min'], lessThanOrEqualTo(55));
        expect(sc['tst_min'], isNull);
      });
    }
  });

  // ── D ────────────────────────────────────────────────────────────────────
  group('D. the sleep profile forgets a night the user blanks', () {
    Future<Map<String, dynamic>> profile() async {
      final r = await LocalDb.baseline('sleep_user_profile');
      return jsonDecode(r!['payload_json'] as String) as Map<String, dynamic>;
    }

    /// The numeric fingerprint of the profile, without timestamps or the
    /// stored observations.
    Map<String, dynamic> core(Map<String, dynamic> p) => {
          for (final e in p.entries)
            if (e.key != 'updated_at_ms' && e.key != 'folded_obs') e.key: e.value,
        };

    const earlierDay = '2025-08-30';
    const earlierObs = {
      'epochs': 800,
      'hr_floor_p5': 48.0,
      'hr_floor_p25': 51.0,
      'hr_sleep_median': 55.0,
      'hr_arousal': 66.0,
      'rmssd_med': 60.0,
      'rmssd_mad': 12.0,
      'enmo_still_cut': 0.02,
      'enmo_move_cut': 0.1,
      'lfhf_med': 1.2,
      'rk_med': 2.0,
    };

    /// A profile one earlier night has already been folded into, the way
    /// the engine stores one: EWMA state, folded day ids, the observation.
    Future<Map<String, dynamic>> seedEarlierNight() async {
      final prof = const ana.SleepUserProfile().fold(ana.SleepNightObservation(
        epochs: 800,
        hrFloorP5: 48.0,
        hrFloorP25: 51.0,
        hrSleepMedian: 55.0,
        hrArousal: 66.0,
        rmssdMed: 60.0,
        rmssdMad: 12.0,
        enmoStillCut: 0.02,
        enmoMoveCut: 0.1,
        lfhfMed: 1.2,
        rkMed: 2.0,
      ));
      final payload = {
        ...prof.toJson(),
        'folded_days': [earlierDay],
        'folded_obs': {earlierDay: earlierObs},
      };
      await LocalDb.putBaseline('sleep_user_profile', jsonEncode(payload));
      return core(payload);
    }

    Future<void> reject() async {
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'rejected');
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d2);
    }

    test('rejecting a folded night rebuilds the profile without it, '
        'idempotently', () async {
      final before = await seedEarlierNight();
      await _derive(_d2);
      final both = await profile();
      expect(both['folded_days'], [earlierDay, _d2],
          reason: 'fixture: the auto night folded');
      expect(both['nights'], 2);

      await reject();

      final after = core(await profile());
      expect(after['folded_days'], [earlierDay]);
      expect(after['nights'], 1);
      for (final k in before.keys) {
        if (k == 'nights' || k == 'folded_days') continue;
        expect(after[k], closeTo(before[k] as num, 1e-9), reason: k);
      }

      // Idempotent: the same edit again changes nothing.
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d2);
      expect(core(await profile()), after);
    });

    test('a user-set window drops the night too; a CONFIRMED one does not',
        () async {
      await seedEarlierNight();
      await _derive(_d2);
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'confirmed');
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d2);
      expect((await profile())['folded_days'], [earlierDay, _d2],
          reason: 'confirmed is a normal staged night');

      await _override(_d2, _sec(2025, 9, 5, 12, 30), _sec(2025, 9, 5, 15, 30),
          'manual');
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d2);
      expect((await profile())['folded_days'], [earlierDay]);
    });

    test('works when the raw is gone (the stored observations are enough)',
        () async {
      await seedEarlierNight();
      await _derive(_d2);
      await _db.delete('decoded_onehz');
      await reject();
      expect((await profile())['folded_days'], [earlierDay]);
      expect((await profile())['nights'], 1);
    });

    test('the only folded night, rejected: back to a cold start', () async {
      await _derive(_d2);
      expect((await profile())['folded_days'], [_d2]);
      await reject();
      expect((await profile())['folded_days'], isEmpty);
      expect((await profile())['nights'], 0);
    });

    test('a profile without stored observations (written before this fix) '
        'is not trusted once a night in it is blanked', () async {
      await seedEarlierNight();
      await _derive(_d2);
      final p = await profile();
      p.remove('folded_obs'); // pre-fix payload: days known, observations not
      await LocalDb.putBaseline('sleep_user_profile', jsonEncode(p));
      await reject();
      final after = await profile();
      // D2's contribution cannot be subtracted from an EWMA, so nothing that
      // cannot be shown to exclude it is kept: an honest cold start.
      expect(after['folded_days'], isEmpty);
      expect(after['nights'], 0);
    });
  });
}
