// A workout-list load with a workout sensor flagged on reads each session's
// 1 Hz window ONCE (not once for the stats and again for the samples), and
// groups the seconds in a registered @heavy worker, not on the UI isolate.
//
//  * EXACTNESS (green before and after): sessionHrStats /
//    sessionHrSamplesBySession / the list's avg/max/min equal the values
//    captured from the pre-change code (goldens, not a second copy of the
//    grouping).
//  * ONCE / WORKER (red before): LocalDb.debugSessionWindowReads is 1 per list
//    load, and the entry `sessionWindowsHeavy` reports from a worker isolate.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

NeutralSample _s(int t, int hr) => NeutralSample(
  anchor: TimeAnchor.arrival,
  tsEpoch: t,
  hr: hr,
  rrMs: const [],
);

int _fnv(Iterable<int> xs) {
  var h = 0x811c9dc5;
  for (final x in xs) {
    h = ((h ^ x) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// Golden: per session, stats then (count, FNV-1a of the samples).
/// Captured from the pre-change code (HEAD 3975bb4e).
const Map<String, Object> _golden = <String, Object>{
  'both': [
    {'avg_hr': 147.9450915141431, 'max_hr': 156, 'min_hr': 140, 'n': 601},
    601,
    219352588,
  ],
  'late': [
    {'avg_hr': 153.9885433715221, 'max_hr': 160, 'min_hr': 90, 'n': 611},
    611,
    47389084,
  ],
};

/// avg / max / min per workout id in the list.
const Map<String, Object> _goldenList = <String, Object>{
  'late': [154, 158, 92],
  'both': [148, 154, 142],
};

Future<void> _seed(int base) async {
  LocalDb.sessionSensorSources = {kBleHrs.id, kPolarPmd.id};
  LocalDb.sessionWearableSource = kGarmin.id;
  // 'both': a strap and a Polar sensor over one window; the strap owns most.
  await _bank(kBleHrs, [
    for (var t = 0; t <= 600; t++) _s(base + t, 140 + t % 17),
  ]);
  await _bank(kPolarPmd, [
    for (var t = 100; t <= 200; t++) _s(base + t, 100 + t % 5),
  ]);
  // 'late': the watch's minutes before a strap put on late.
  final b2 = base + 4000;
  await _bank(kGarmin, [
    for (var t = 0; t <= 1200; t += 60) _s(b2 + t, 90 + t % 7),
  ]);
  await _bank(kBleHrs, [
    for (var t = 600; t <= 1200; t++) _s(b2 + t, 150 + t % 11),
  ]);
  for (final (id, s, e) in [
    ('both', base, base + 600),
    ('late', b2, b2 + 1200),
  ]) {
    await LocalDb.putSession({
      'id': id,
      'start_ts': s,
      'end_ts': e,
      'type': 'run',
      'status': 'done',
      'created_at': e,
    });
  }
}

Map<String, Object?> _shape(
  Map<String, Map<String, num>> stats,
  Map<String, List<int>> samples,
) => {
  for (final id in (stats.keys.toList()..sort()))
    id: [
      {for (final k in (stats[id]!.keys.toList()..sort())) k: stats[id]![k]},
      samples[id]!.length,
      _fnv(samples[id]!),
    ],
};

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late int base;
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'session_windows_once_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 20000;
    await _seed(base);
    WorkerAudit.reset();
  });

  tearDown(() async {
    LocalDb.sessionSensorSources = const {};
    LocalDb.sessionWearableSource = null;
    WorkerAudit.reset();
    await LocalDb.close();
  });

  test('stats and samples are unchanged (golden)', () async {
    final stats = await LocalDb.sessionHrStats(
      base - 1,
      base + 9000,
      maxHrCeiling: 200,
      minHrFloor: 30,
    );
    final samples = await LocalDb.sessionHrSamplesBySession(
      base - 1,
      base + 9000,
    );
    final got = _shape(stats, samples);
    expect(jsonEncode(got), jsonEncode(_golden));
  });

  test('a workout list load reads the session windows once', () async {
    final before = LocalDb.debugSessionWindowReads;
    final out = await LocalRepositoryImpl(
      getProfileMap: () => const {'age': 30},
    ).getWorkouts(range: 'month');
    final reads = LocalDb.debugSessionWindowReads - before;
    final ws = {
      for (final w in (out['workouts'] as List).cast<Map>()) w['id']: w,
    };
    final list = {
      for (final e in ws.entries)
        e.key: [e.value['avg_hr'], e.value['max_hr'], e.value['min_hr']],
    };
    // ignore: avoid_print
    print('LIST ${jsonEncode(list)}');
    expect(
      jsonEncode({for (final k in list.keys.toList()..sort()) k: list[k]}),
      jsonEncode({
        for (final k in _goldenList.keys.toList()..sort()) k: _goldenList[k],
      }),
      reason: 'list unchanged',
    );
    expect(reads, 1, reason: 'one fetch feeds the stats and the samples');
  });

  test('the windows are grouped in a worker', () async {
    final entries = <EntryEvent>[];
    WorkerAudit.onEntry = entries.add;
    await LocalDb.sessionHrReads(base - 1, base + 9000);
    await pumpEventQueue();
    final hit = entries.where((e) => e.entry.contains('sessionWindowsHeavy'));
    expect(hit, isNotEmpty, reason: 'seen: ${entries.map((e) => e.entry)}');
    for (final e in hit) {
      expect(e.isolateId, isNot(WorkerAudit.currentIsolateId));
    }
    expect(
      kWorkerEntries.where(
        (e) => e.symbol.toString().contains('sessionWindowsHeavy'),
      ),
      isNotEmpty,
    );
  });
}
