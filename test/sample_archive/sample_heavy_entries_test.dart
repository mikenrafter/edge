// The sample archive dispatches its heavy work through the REGISTERED entries
// (design 02 follow-up 3). Before, three inline `Isolate.run` closures (encode in
// `_archiveDevice`, decode + overlay in `reconstructWithOrigin`, the carve in
// `carveSamplePart`) ran heavy work the dispatcher audit could not see and the
// guard baselined as dispatcherClosureContract.
//
// Each public call below must (1) report a dispatch (`WorkerAudit.dispatched`,
// kind Dispatcher.run, label 'sample encode' / 'sample reconstruct' /
// 'sample carve'), (2) run the registered entry in a DIFFERENT isolate under
// THAT dispatch's token, and (3) give exactly the bytes the old path gave.
//
// Fixed dates (TZ=UTC), injected `nowSec`; no test reads a clock.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';
import 'package:openstrap_edge/data/sample_import.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

import '../support/sample_fixtures.dart';
import '../support/sample_heavy_fixtures.dart';

const _day = '2026-10-03';
const _now = 1791000000;
const _slots = 1200; // twenty minutes from local midnight

late int _d0;
final dispatches = <DispatchEvent>[];
final entries = <EntryEvent>[];

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

Future<void> _seed() async {
  final db = await LocalDb.instance;
  final day = fixtureDay(gaps: false);
  final b = db.batch();
  for (var i = 0; i < _slots; i++) {
    final ts = _d0 + i;
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': day['hr']![i]?.round(),
      'ax': day['ax']![i],
      'ay': day['ay']![i],
      'az': day['az']![i],
      'skin_temp_c': day['skin_temp_c']![i],
    });
  }
  await b.commit(noResult: true);
}

/// The dispatch with [label], its entry reports, checked against the contract.
List<EntryEvent> _reportsOf(String label, String entry) {
  final d = dispatches.where((d) => d.label == label).toList();
  expect(d, hasLength(1), reason: 'one "$label" dispatch (saw $dispatches)');
  expect(d.single.kind, Dispatcher.run);
  final mine = [for (final e in entries) if (e.dispatchId == d.single.id) e];
  expect([for (final e in mine) e.entry], contains(entry),
      reason: 'the "$label" dispatch ran $entry under its own token');
  for (final e in mine) {
    expect(e.isolateId, isNot(d.single.isolateId),
        reason: '$entry ran in a worker, not on the dispatching isolate');
  }
  return mine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d0 = localDayStartSec(_day)!;
  });
  setUp(() {
    dispatches.clear();
    entries.clear();
    WorkerAudit.onDispatch = dispatches.add;
    WorkerAudit.onEntry = entries.add;
  });
  tearDown(WorkerAudit.reset);
  tearDownAll(() async => LocalDb.close());

  test('archiveDay dispatches the registered encode entry, and the stored blobs '
      'are byte-identical to SampleCodec.encode on the same slots', () async {
    await _freshDb('sample_heavy_encode.db');
    await _seed();
    final written = await SampleArchiver.archiveDay(_day, nowSec: _now);
    expect(written, 5);
    await pumpEventQueue();
    _reportsOf('sample encode', 'encodeSampleSignalsHeavy');

    // The oracle: the slots straight from the seeded rows, encoded with the
    // archiver's default modes by the codec itself (the old closure's body).
    final day = fixtureDay(gaps: false);
    for (final r in await SampleArchiver.rows(_day)) {
      final slots = List<double?>.filled(86400, null);
      for (var i = 0; i < _slots; i++) {
        var v = day[r.signal]![i];
        if (r.signal == 'hr') v = v?.round().toDouble();
        slots[i] = v;
      }
      final want = SampleCodec.encode(r.signal, slots,
          mode: SampleArchiver.defaultModes[r.signal]!);
      expect(r.blob, want.blob, reason: '${r.signal} blob');
      expect(r.nValid, want.stats.nValid, reason: '${r.signal} n_valid');
      expect(r.rmsErr, want.stats.rmsErr, reason: '${r.signal} rms');
      expect(r.maxErr, want.stats.maxErr, reason: '${r.signal} max');
    }
  });

  test('reconstructWithOrigin dispatches the registered reconstruct entry and '
      'equals the decode + overlay of the stored parts', () async {
    await _freshDb('sample_heavy_reconstruct.db');
    await _seed();
    await SampleArchiver.archiveDay(_day, nowSec: _now);
    dispatches.clear();
    entries.clear();

    final got = await SampleArchiver.reconstructWithOrigin(_day, 'hr');
    await pumpEventQueue();
    expect(got, isNotNull);
    _reportsOf('sample reconstruct', 'reconstructSamplePartsHeavy');

    final parts = [
      for (final r in await SampleArchiver.rows(_day))
        if (r.signal == 'hr' && SampleCodec.hasSamples(r.blob))
          SampleBlobPart(r.originSec, r.blob)
    ];
    final want = sampleReconstructOracle(SampleReconstructInput(parts: parts));
    expect(got!.originSec, want.originSec);
    expect(got.samples, want.samples);
  });

  test('carveSamplePart dispatches the registered carve entry and equals the '
      'sync carve', () async {
    final input = sampleCarveInput();
    final got = await carveSamplePart(input.blob, input.coveredMinutes.toSet(),
        valid: input.valid, rmsErr: input.rmsErr, maxErr: input.maxErr);
    await pumpEventQueue();
    _reportsOf('sample carve', 'carveSamplePartHeavy');

    final want = carveSamplePartSync(
        input.blob, input.coveredMinutes.toSet(),
        valid: input.valid, rmsErr: input.rmsErr, maxErr: input.maxErr)!;
    expect(got!.blob, Uint8List.fromList(want.blob));
    expect(got.nValid, want.nValid);
    expect(got.rmsErr, want.rmsErr);
    expect(got.maxErr, want.maxErr);
  });

  test('two archive calls are two dispatches, each with its own report', () async {
    await _freshDb('sample_heavy_two.db');
    await _seed();
    await SampleArchiver.archiveDay(_day, nowSec: _now);
    await SampleArchiver.reconstructWithOrigin(_day, 'hr');
    await SampleArchiver.reconstructWithOrigin(_day, 'skin_temp_c');
    await pumpEventQueue();
    expect([for (final d in dispatches) d.label],
        ['sample encode', 'sample reconstruct', 'sample reconstruct']);
    final ids = [for (final d in dispatches) d.id];
    expect(ids.toSet(), hasLength(ids.length), reason: 'distinct dispatch ids');
    for (final d in dispatches) {
      expect(entries.where((e) => e.dispatchId == d.id), isNotEmpty,
          reason: 'dispatch ${d.id} (${d.label}) reported nothing of its own');
    }
  });
}
