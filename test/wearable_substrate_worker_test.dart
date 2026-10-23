// A wearable's day substrate (decode rows, rebuild channels, merge a strap's
// session, sort) is O(day samples) work. `_prepareTargetDay` must not do it on
// the UI isolate: it goes through a registered @heavy worker entry, named
// `wearableSubstrateHeavy`, and the engine receives a typed Substrate.
//
//  * EXACTNESS (green today, must stay green): for Colmi, Ultrahuman, Garmin
//    (sparse HR) and Oura days, and a day with a strap session laid over it,
//    the substrate `wearableSubstrate` returns fingerprints to the value
//    captured from the main-isolate builders before the move, and the stored
//    day of a second engine pass equals the first (the stored-day payload
//    itself is pinned by the synthetic_*_day tests). Goldens, not a second copy of the
//    builder: after the move the builder and the worker are the same code, so
//    an oracle that calls "the current builder" would be vacuous.
//  * WORKER (red today): the engine's wearable load reports the entry from a
//    worker isolate, matched to a dispatch, once per loaded range.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/ble/ultrahuman_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart'
    show kGarminFamily;
import 'package:openstrap_edge/compute/inputs/oura_inputs.dart'
    show kOuraFamily;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);
final int _from = SyntheticDay.sec(DateTime(2026, 10, 4));
final int _to = _from + 86399 + 3 * 3600; // the day plus the nap buffer

const String _colmi = 'colmi-w', _uh = 'ultrahuman-w', _garmin = 'garmin-w';
const String _oura = 'oura-w';

/// The golden per family: FNV-1a over the substrate's JSON, and its length,
/// keyed by the zone's UTC offset on the fixture day (day labels are local, so
/// the substrate window moves with the zone). The -360 (MDT) set was captured
/// from the main-isolate builders at 8c065426; the UTC set from the worker at
/// 89963e2e, where the MDT set still matches.
const Map<int, Map<String, (int, int)>> _goldens = {
  -360: {
    'colmi': (264, 2162150457),
    'colmi_night': (85, 3253111834),
    'colmi_strap': (1161, 695549905),
    'garmin': (1320, 2083733184),
    'oura': (288, 3287909487),
    'ultrahuman': (264, 1939530137),
  },
  0: {
    'colmi': (264, 1350492575),
    'colmi_night': (85, 2279222205),
    'colmi_strap': (1161, 678983046),
    'garmin': (1320, 753870275),
    'oura': (288, 1234590920),
    'ultrahuman': (264, 3759334063),
  },
};
final Map<String, (int, int)>? _golden =
    _goldens[DateTime(2026, 10, 4).timeZoneOffset.inMinutes];
const bool _printGoldens = bool.fromEnvironment('PRINT_GOLDENS');

int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(s)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h;
}

(int, int) _fp(Substrate s) => (s.length, _fnv(jsonEncode(s.toJson())));

Future<void> _expectGolden(String key, (String, String) w,
    {int? from, int? to}) async {
  final sub = await wearableSubstrate(w, from ?? _from, to ?? _to);
  expect(sub.length, greaterThan(0), reason: '$key: fixture has rows');
  final got = _fp(sub);
  if (_printGoldens) {
    // ignore: avoid_print
    print("GOLDEN '$key': $got");
  }
  if (_golden == null) {
    markTestSkipped('goldens exist for TZ=UTC and America/Denver only');
    return;
  }
  expect(got, _golden![key], reason: '$key substrate changed');
}

Future<String> _stored() async {
  final row = (await LocalDb.dayResult(_dayId))!;
  final payload = jsonDecode(row['payload_json'] as String) as Map;
  payload.remove('computed_at');
  return jsonEncode(payload);
}

class _Feed extends BandAdapter {
  const _Feed(this.entry, this.samples);
  @override
  final BandEntry entry;
  final List<NeutralSample> samples;
  @override
  Map<InputSignal, Duration> get signals => const {};
  @override
  Stream<BandEvent> run(BandLink link) async* {
    yield SampleBatch(samples);
  }
}

Future<void> _bank(BandEntry entry, List<NeutralSample> samples) async {
  final host = BandHost(adapter: _Feed(entry, samples), deviceId: entry.id);
  await host.run(ReplayBandLink());
  await host.stop();
}

Future<void> _insertOura(Database db) async {
  // A ring's HR every 5 min, a temperature slot between, beats in the night.
  final b = db.batch();
  var n = 0;
  for (var t = _from; t < _from + 86400; t += 300) {
    final night = t < _from + 6 * 3600;
    b.insert('decoded_onehz', {
      'device_id': _oura,
      'ts_ms': t * 1000,
      'rec_ts': t,
      'counter': ++n,
      'hr': (night ? 52 : 74) + (t ~/ 300) % 7,
      'device_family': kOuraFamily,
      'source': kOuraFamily,
    });
    b.insert('decoded_onehz', {
      'device_id': _oura,
      'ts_ms': (t + 150) * 1000,
      'rec_ts': t + 150,
      'counter': ++n,
      'skin_temp_c': 33.0 + (t ~/ 300) % 5 * 0.25,
      'device_family': kOuraFamily,
      'source': kOuraFamily,
    });
  }
  for (var i = 0; i < 400; i++) {
    final t = _from + 600 + i;
    b.insert('decoded_rr', {
      'device_id': _oura,
      'ts_ms': t * 1000,
      'rec_ts': t,
      'beat_index': 0,
      'rr_ts_ms': t * 1000 + 400,
      'rr_ms': 900 + (i * 37) % 120,
      'device_family': kOuraFamily,
      'source': kOuraFamily,
    });
  }
  await b.commit(noResult: true);
}

void main() {
  final dispatches = <DispatchEvent>[];
  final entries = <EntryEvent>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'wearable_substrate_worker_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.sessionSensorSources = const {};
    LocalDb.sessionWearableSource = null;
    for (final (id, adapter, remote) in [
      (_colmi, 'colmi', 'AA:BB:CC:00:00:11'),
      (_uh, 'ultrahuman', 'AA:BB:CC:00:00:12'),
      (_garmin, 'garmin', 'AA:BB:CC:00:00:13'),
      (_oura, 'oura', 'AA:BB:CC:00:00:14'),
    ]) {
      await LocalDb.upsertDevice(
          id: id, adapterId: adapter, remoteId: remote, label: id);
    }
    int now() => SyntheticDay.sec(_now);
    await ColmiLink.instance.ingestForTest(
        _colmi, (_, w) => SyntheticDay.colmiRingReply(_days, w, _now),
        nowSeconds: now);
    await UltrahumanLink.instance.ingestForTest(_uh,
        (_, w) => SyntheticDay.ultrahumanRingReply(
            SyntheticDay.ultrahumanDays(_days), w),
        nowSeconds: now);
    await GarminLink.instance.ingestForTest(
        _garmin, GarminWatchScript(SyntheticDay.garminDays(_days)).reply,
        nowSeconds: now);
    await _insertOura(await LocalDb.instance);
  });

  tearDown(() {
    WorkerAudit.reset();
    LocalDb.sessionSensorSources = const {};
    LocalDb.sessionWearableSource = null;
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('exactness: the wearable day substrate is bit-identical', () {
    test('Colmi', () => _expectGolden('colmi', (_colmi, 'colmi')));
    test('Ultrahuman', () => _expectGolden('ultrahuman', (_uh, 'ultrahuman')));
    test('Garmin (sparse HR)',
        () => _expectGolden('garmin', (_garmin, kGarminFamily)));
    test('Oura (HR + temperature + beats)',
        () => _expectGolden('oura', (_oura, kOuraFamily)));
    test('a sub-range (the sleep window) is the same slice of rows', () async {
      await _expectGolden('colmi_night', (_colmi, 'colmi'),
          from: _from + 3600, to: _from + 8 * 3600);
    });
  });

  group('the worker', () {
    test('the entry is registered', () {
      expect(
          kWorkerEntries
              .where((e) => e.symbol.toString().contains('wearableSubstrateHeavy')),
          isNotEmpty,
          reason: 'register #wearableSubstrateHeavy in kWorkerEntries');
    });

    test('a wearable day derive loads its substrate in a worker, and stores '
        'the same day', () async {
      await LocalDb.setCursor(kActiveWearableCursor, _colmi);
      await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
      dispatches.clear();
      entries.clear();
      WorkerAudit.onDispatch = dispatches.add;
      WorkerAudit.onEntry = entries.add;

      final engine = DerivationEngine();
      expect(await engine.runDays(_profile, {_dayId}, force: true), 1);
      await pumpEventQueue();

      final wear = entries
          .where((e) => e.entry.contains('wearableSubstrateHeavy'))
          .toList();
      expect(wear, isNotEmpty,
          reason: 'entries seen: ${entries.map((e) => e.entry).toSet()}');
      for (final e in wear) {
        expect(e.isolateId, isNot(WorkerAudit.currentIsolateId),
            reason: 'ran on the UI isolate');
        expect(e.dispatchId, isNotNull);
        expect(dispatches.map((d) => d.id), contains(e.dispatchId),
            reason: 'every report is matched to a dispatch');
      }
      // The day range and the sleep window are two loads per wearable day.
      expect(wear.length, greaterThanOrEqualTo(2));

      // The stored day equals a second, separate pass over the same rows.
      final first = await _stored();
      WorkerAudit.reset();
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
      expect(await _stored(), first);
    });

    test('a strap session laid over the wearable day is unchanged', () async {
      LocalDb.sessionSensorSources = {kBleHrs.id};
      final t0 = _from + 14 * 3600;
      await _bank(kBleHrs, [
        for (var t = t0; t <= t0 + 900; t++)
          NeutralSample(
              anchor: TimeAnchor.arrival,
              tsEpoch: t,
              hr: 120 + t % 9,
              rrMs: [480 + t % 50]),
      ]);
      await LocalDb.putSession({
        'id': 'strap-over-colmi',
        'start_ts': t0,
        'end_ts': t0 + 900,
        'type': 'run',
        'status': 'done',
        'created_at': t0 + 900,
      });
      await _expectGolden('colmi_strap', (_colmi, 'colmi'));
    });
  });
}
