// ignore_for_file: file_names
// The @SendableShape round trip for the wearable substrate entry (design 02:
// its input carries sqflite row maps and a Substrate, its result a Substrate
// transfer map, all outside the closed grammar, so the entry owes a real
// Isolate.run round trip).
//
// Pins: `WearableSubstrateInput` built over REAL sqflite rows (the
// `QueryResultSet` the UI isolate hands on unread) and a Substrate crosses into
// a worker with every field intact, and `WearableSubstrateResult` comes back
// intact, adopting to the substrate the same call on this isolate builds.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/wearable_substrate_heavy.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'guards/support/sendability.dart';

const int _t0 = 1791100000;

Object? _inputShape(WearableSubstrateInput i) => [
      i.plan.name,
      i.family,
      i.deviceId,
      i.from,
      i.to,
      for (final l in [i.hr, i.temps, i.records, i.beats, i.strapBeats, i.strapHr])
        l == null ? null : [for (final r in l) Map.of(r)],
      i.base?.toJson(),
      i.emptyFamily,
    ];

void main() {
  late Database db;
  late List<Map<String, Object?>> hrRows;

  setUpAll(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE decoded_onehz (rec_ts INTEGER, hr INTEGER)');
    for (var i = 0; i < 40; i++) {
      await db.insert('decoded_onehz', {'rec_ts': _t0 + i * 300, 'hr': 55 + i % 9});
    }
    hrRows = await db.rawQuery(
        'SELECT rec_ts, hr FROM decoded_onehz ORDER BY rec_ts');
  });

  tearDownAll(() => db.close());
  tearDown(WorkerInit.resetForTest);

  WearableSubstrateInput input() => WearableSubstrateInput(
        plan: WearablePlan.sparseHr,
        family: 'garmin',
        deviceId: 'dev',
        from: _t0,
        to: _t0 + 40 * 300,
        hr: hrRows,
        strapBeats: const [],
        strapHr: const [],
        base: Substrate.empty,
        emptyFamily: 'garmin',
      );

  test('the input crosses an isolate boundary with every field intact',
      () async {
    await expectIsolateRoundTrip<WearableSubstrateInput>(input(),
        project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact',
      () async {
    final r = WearableSubstrateResult(
      substrate: Substrate.empty.toJson(),
      temps: const [
        [1, 2, 3]
      ],
      records: const [
        [1.0, double.infinity, 3.0]
      ],
    );
    final copy = await isolateRoundTrip<WearableSubstrateResult>(r);
    expect(jsonEncode(copy.substrate), jsonEncode(r.substrate));
    expect(copy.temps, r.temps);
    expect(copy.records, r.records);
  });

  test('a worker answers what the same call on this isolate answers',
      () async {
    final inp = input();
    final here = Substrate.fromTransfer(
        wearableSubstrateHeavy(wearableWorkerInputs, inp).substrate!);
    WorkerInit.resetForTest();
    final there = Substrate.fromTransfer((await Isolate.run(
            () => wearableSubstrateHeavy(wearableWorkerInputs, inp)))
        .substrate!);
    expect(here.length, 40);
    expect(jsonEncode(there.toJson()), jsonEncode(here.toJson()));
  });
}
