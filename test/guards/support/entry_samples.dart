// entry_samples.dart — one sample per registered worker entry, used by the
// per-entry sendability and determinism tests (design 02).
//
// Keyed by a substring of `WorkerEntry.symbol.toString()` (private symbols are
// library-scoped, so they cannot be compared by value from a test library).
// Adding a `WorkerEntry` without a sample here fails
// heavy_sendability_helper_test ("every kWorkerEntries symbol has a sample").
//
// What a sample proves, per entry:
//   * the ARGUMENT and RESULT types cross a real `Isolate.run` boundary;
//   * for entries a test can call: the worker's answer equals the direct call's
//     (same inputs => same output, run in a different isolate).
// Entries whose function is private (and whose argument types are private
// classes) cannot be called from a test library; their sample round-trips the
// declared argument/result SHAPES, and their behaviour is covered by the tests
// of the library that owns them.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';

import '../../support/incremental_day_fixture.dart';
import 'sendability.dart';

typedef EntrySample = ({
  Future<void> Function() roundTrip,
});

/// Worker answer == direct answer, both compared as JSON.
Future<void> _sameInWorker<T>(T Function() call, {Object? Function(T)? json}) async {
  final j = json ?? (T v) => v;
  final direct = jsonEncode(j(call()));
  final inWorker = jsonEncode(j(await Isolate.run(call)));
  expect(inWorker, direct, reason: 'same inputs, same output, other isolate');
}

final Map<String, EntrySample> kEntrySamples = <String, EntrySample>{
  'deriveDayBundle': (
    roundTrip: () async {
      final input = copyDay(incrementalDay());
      await expectIsolateRoundTrip<Map<String, dynamic>>(input);
      await _sameInWorker(() => deriveDayBundle(copyDay(input)));
    },
  ),
  'buildCrossDayBundle': (
    roundTrip: () async {
      const days = <Map<String, dynamic>>[];
      await expectIsolateRoundTrip<List<Map<String, dynamic>>>(days);
      await _sameInWorker(() => buildCrossDayBundle(days, const {}));
    },
  ),
  'foldDayCheckpoint': (
    roundTrip: () async {
      Uint8List? fold() => foldDayCheckpoint(
            base: null,
            alreadyFolded: 0,
            ts: [for (var i = 0; i < 120; i++) 1760000000 + i],
            hr: [for (var i = 0; i < 120; i++) 60 + i % 5],
            ax: List<double>.filled(120, 0),
            ay: List<double>.filled(120, 0),
            az: List<double>.filled(120, 1),
            stepCounter: [for (var i = 0; i < 120; i++) i],
            age: 35,
            stepModulus: 65536,
          );
      final blob = fold();
      if (blob != null) await expectIsolateRoundTrip<Uint8List>(blob);
      await _sameInWorker(fold, json: (Uint8List? b) => b?.toList());
    },
  ),
  'kcalMinutesForDayHeavy': (
    roundTrip: () async {
      Map<String, dynamic>? kcal() => DerivationEngine.kcalMinutesForDayHeavy(
            daySub: Substrate.empty,
            profile: const Profile(),
            nocturnalRhr: null,
            sleepOnsetSec: 0,
            sleepOffsetSec: 0,
          );
      await _sameInWorker(kcal);
    },
  ),
  'derivationPrepareWorker': (
    roundTrip: () async {
      // The spawn protocol: the worker answers with its own SendPort.
      final port = ReceivePort();
      final iso = await Isolate.spawn(derivationPrepareWorker, port.sendPort);
      final first = await port.first;
      iso.kill(priority: Isolate.immediate);
      expect(first, isA<SendPort>());
    },
  ),
  '_dayBlocksIsolateEntry': (
    roundTrip: () async {
      // Argument is (SendPort, _DayBlocksInput): the SendPort half is the only
      // part a test can build; the private input class is covered by the
      // engine tests that drive the spawn for real.
      final port = ReceivePort();
      addTearDown(port.close);
      await expectIsolateRoundTrip<(SendPort, int)>((port.sendPort, 3),
          project: (r) => r.$2);
    },
  ),
  '_reencodeBatchHeavy': (
    roundTrip: () async {
      await expectIsolateRoundTrip<List<String>>(['{"a":1}', '']);
      await expectIsolateRoundTrip<List<String?>>(['x', null]);
    },
  ),
  '_spotCheckComputeHeavy': (
    roundTrip: () async {
      await expectIsolateRoundTrip<List<String>>(['00', '01']);
      await expectIsolateRoundTrip<Map<String, dynamic>>(
          {'n_beats': 3, 'confidence': 0.5, 'mean_hr': null});
    },
  ),
  '_breathingCoherenceComputeHeavy': (
    roundTrip: () async {
      await expectIsolateRoundTrip<(List<String>, double?)>((['00'], 0.1));
      await expectIsolateRoundTrip<Map<String, dynamic>>(
          {'coherence': 0.4, 'present': true});
    },
  ),
  '_writeZipHeavy': (
    roundTrip: () async {
      await expectIsolateRoundTrip<(String, List<List<String>>, String)>(
        ('/tmp/out.zip', [
          ['name', '/tmp/in']
        ], '{}'),
      );
    },
  ),
  'observeNaturalSync': (
    roundTrip: () async {
      final req = NaturalObserveRequest(
          nowMs: 1790000000000, hr: const [], accel: const [], rr: const []);
      await _sameInWorker(() => observeNaturalSync(req),
          json: (NaturalObserveResult r) =>
              [r.observation.toJson(), r.nextState]);
    },
  ),
  'encryptBackupFile': (
    roundTrip: () async {
      final tmp = await Directory.systemTemp.createTemp('entry_sample_enc');
      addTearDown(() => tmp.delete(recursive: true));
      final src = File('${tmp.path}/in')..writeAsBytesSync([1, 2, 3, 4]);
      final dest = File('${tmp.path}/out.osbk');
      await Isolate.run(
          () => encryptBackupFile(src, dest, 'pw', iterations: 1000));
      expect(dest.existsSync(), isTrue);
      expect(dest.readAsBytesSync(), isNot(contains(isNull)));
    },
  ),
  'decryptBackupFile': (
    roundTrip: () async {
      final tmp = await Directory.systemTemp.createTemp('entry_sample_dec');
      addTearDown(() => tmp.delete(recursive: true));
      final src = File('${tmp.path}/in')..writeAsBytesSync([9, 8, 7, 6, 5]);
      final enc = File('${tmp.path}/out.osbk');
      final back = File('${tmp.path}/back');
      await encryptBackupFile(src, enc, 'pw', iterations: 1000);
      await Isolate.run(() => decryptBackupFile(enc, back, 'pw'));
      expect(back.readAsBytesSync(), [9, 8, 7, 6, 5]);
    },
  ),
};
