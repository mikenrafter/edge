// Observed max HR, per finished session. `_dayHrCeiling` re-ran
// `sessionHrCeiling` over every saved session of the day on every derive, and
// a finished session's samples do not change. The engine now keeps each
// finished session's result keyed by the session, its clipped window, the
// decoded-sample revision over that window (`input_rev`) and the device
// ownership that produced the substrate. A periodic awake pass reuses a hit;
// every other mode computes in full. Output stays what a full derive stores.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/incremental_compare.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

/// [n] seconds of 1 Hz data, every second moving at [hrBpm].
Substrate _movingSub(int n, {int hrBpm = 170, String? family = 'gen4'}) {
  const t0 = 1780000000;
  return Substrate(
    tsSec: [for (var i = 0; i < n; i++) t0 + i],
    hr: List<int>.filled(n, hrBpm),
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0),
    ay: List<double>.filled(n, 0),
    az: List<double>.filled(n, 1.30),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    deviceFamily: family,
  );
}

List<Map<String, dynamic>> _session({String status = 'done'}) => [
  {
    'id': 's1',
    'type': 'run',
    'status': status,
    'start_ts': 1780000000,
    'end_ts': 1780000060,
  },
];

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

Future<void> _put(int ts, int hr, double az) async {
  final db = await LocalDb.instance;
  await db.insert('decoded_onehz', {
    'device_id': '',
    'ts_ms': ts * 1000,
    'rec_ts': ts,
    'counter': ts,
    'hr': hr,
    'ax': 0.0,
    'ay': 0.0,
    'az': az,
    'device_family': 'gen4',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<Map<String, dynamic>> _stored(String day) async {
  final row = (await LocalDb.dayResult(day))!;
  final payload =
      jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
  payload.remove('computed_at');
  return payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dayHrCeiling reuse seam', () {
    test('a reused finished session is not recomputed; a computed one is '
        'reported for the cache', () {
      final sub = _movingSub(60);
      final plain = DerivationEngine.dayHrCeiling(sub, _session());
      expect((plain['value'] as Map)['bpm'], 170);

      final computed = <String, ({Map<String, dynamic> json, double? bpm})>{};
      final withOut = DerivationEngine.dayHrCeiling(
        sub,
        _session(),
        computed: computed,
      );
      expect(jsonEncode(withOut), jsonEncode(plain),
          reason: 'collecting results changes nothing');
      expect(computed.keys, ['s1']);

      // A sentinel proves the scan was skipped: the answer is the cached one.
      final sentinel = {
        ...computed['s1']!.json,
        'value': {...(computed['s1']!.json['value'] as Map), 'bpm': 199.0},
      };
      final reused = DerivationEngine.dayHrCeiling(
        sub,
        _session(),
        reuse: {'s1': (json: sentinel, bpm: 199.0)},
      );
      expect((reused['value'] as Map)['bpm'], 199.0);
      expect(reused['session_id'], 's1');
      expect(reused['session_type'], 'run');
    });

    test('reusing a recomputed-equal entry is bit-identical to computing', () {
      final sub = _movingSub(60);
      final computed = <String, ({Map<String, dynamic> json, double? bpm})>{};
      final plain = DerivationEngine.dayHrCeiling(
        sub,
        _session(),
        computed: computed,
      );
      final reused = DerivationEngine.dayHrCeiling(
        sub,
        _session(),
        reuse: computed,
      );
      expect(jsonEncode(reused), jsonEncode(plain));
    });

    test('an absent result is cached too (most sessions hold no ceiling)', () {
      final still = _movingSub(60);
      final computed = <String, ({Map<String, dynamic> json, double? bpm})>{};
      final plain = DerivationEngine.dayHrCeiling(
        Substrate(
          tsSec: still.tsSec,
          hr: still.hr,
          rrTsMs: const [],
          rrMs: const [],
          ax: List<double>.filled(60, 0),
          ay: List<double>.filled(60, 0),
          az: List<double>.filled(60, 1.005),
          spo2Red: List<int>.filled(60, 0),
          spo2Ir: List<int>.filled(60, 0),
          skinTemp: List<int>.filled(60, 0),
          skinContact: List<int>.filled(60, 0),
          deviceFamily: 'gen4',
        ),
        _session(),
        computed: computed,
      );
      expect(plain['value'], '—');
      expect(computed['s1']!.bpm, isNull);
    });

    test('a live session is never reported for the cache', () {
      final computed = <String, ({Map<String, dynamic> json, double? bpm})>{};
      DerivationEngine.dayHrCeiling(
        _movingSub(60),
        _session(status: 'live'),
        computed: computed,
      );
      expect(computed, isEmpty);
    });
  });

  group('engine passes', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'incremental_session_ceiling_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('a finished session is scanned once across awake passes, rescanned '
        'when its samples change, and always matches a forced derive',
        () async {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day - 1);
      final day = dayLabelOf(midnight);
      final start = _sec(midnight.add(const Duration(hours: 10)));
      // 10:00-11:00. 10:10-10:14 is a held 170 bpm effort with real motion.
      for (var i = 0; i < 3600; i++) {
        final inEffort = i >= 600 && i < 840;
        await _put(start + i, inEffort ? 170 : 90, inEffort ? 1.30 : 1.005);
      }
      await LocalDb.putSession({
        'id': 'ses1',
        'start_ts': start + 300,
        'end_ts': start + 1800,
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': start * 1000,
      });

      final awake = DerivationEngine();
      Future<void> lightPass() => awake.run(
        _profile,
        changedOnly: true,
        calculationMode: ana.CalculationMode.periodicAwake,
      );

      await lightPass();
      expect(awake.debugCeilingComputed, 1);
      expect(awake.debugCeilingHits, 0);
      expect((await _scalars(day))['hr_ceiling_bpm'], 170);

      // Data arrives after the session, in a later revision bucket.
      for (var i = 3600; i < 3900; i++) {
        await _put(start + i, 95, 1.005);
      }
      await lightPass();
      expect(awake.debugCeilingHits, 1, reason: 'reused the finished session');
      expect(awake.debugCeilingComputed, 1, reason: 'and did not rescan it');
      final reused = await _stored(day);

      final oracle = DerivationEngine();
      await oracle.run(_profile, force: true);
      expect(oracle.debugCeilingHits, 0, reason: 'a forced run never reuses');
      expectSameJson(reused, await _stored(day));

      // A sample inside the session window is replaced: the revision moves.
      for (var i = 600; i < 840; i++) {
        await _put(start + i, 150, 1.30);
      }
      await lightPass();
      expect(awake.debugCeilingComputed, 2, reason: 'rescanned after the edit');
      expect((await _scalars(day))['hr_ceiling_bpm'], 150);
      final edited = await _stored(day);
      await oracle.run(_profile, force: true);
      expectSameJson(edited, await _stored(day));
    });
  });
}

Future<Map<String, dynamic>> _scalars(String day) async =>
    ((await _stored(day))['scalars'] as Map).cast<String, dynamic>();
