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
import 'package:openstrap_edge/compute/day_curve_states.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/day_tail_fold.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';
import 'package:openstrap_edge/data/sample_import.dart' show SampleCarved;
import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';

import '../../support/day_stream_fixture.dart';
import '../../support/incremental_day_fixture.dart';
import '../../support/sample_heavy_fixtures.dart';
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
  'foldDayTailHeavy': (
    roundTrip: () async {
      // Empty checkpoint states (as a checkpoint blob) and a short tail in; the
      // persisted envelopes, curves and the tail out. The @SendableShape round
      // trip itself is in test/sendable_foldDayTailHeavy_test.dart.
      final input = DayTailInput(
        checkpoint:
            encodeDayResumeState(DayResumeState(curves: DayCurveStates(cut: 0.02))),
        tailRr: const [812.0, 805.0, 790.0],
        tailTs: const [1760000001000.0, 1760000002000.0, 1760000003000.0],
        accTs: const [1760000000, 1760000001, 1760000002, 1760000003],
        ax: const [0.0, 0.1, 0.0, 0.1],
        ay: const [0.0, 0.0, 0.1, 0.1],
        az: const [1.0, 1.0, 0.99, 1.0],
        onsetSec: 1760000000,
        offsetSec: 1760003600,
      );
      const inputs = WorkerInputs(nowEpochMs: 1, zoneId: 'UTC', localeTag: 'en');
      await _sameInWorker(() => foldDayTailHeavy(inputs, input),
          json: (DayTailResult? r) => r == null
              ? null
              : [r.irregular, r.hrv, r.resp, r.daytime, r.tailRr, r.tailTs]);
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
      // The REAL message: (reply SendPort, _DayBlocksInput, audit SendPort?,
      // dispatch id).
      // The input is built by the engine's @visibleForTesting factory with every
      // nested kind populated (substrates with typed beats, the calculation
      // state, records in ceilingReuse, NapEdit, spans, saved sessions, the
      // streamed day figures), so the sample proves the production argument type
      // crosses, not a stand-in.
      final beats = synthBeats(const SynthBeats(seed: 3, seconds: 1800));
      final accel = synthAccel(5, 1760000000, 1760000000 + 1800);
      final input = DerivationEngine.dayBlocksInputForTest(
        daySub: substrateOf(beats, accel),
        date: '2025-10-09',
        dayStartSec: 1760000000,
      );
      final before = DerivationEngine.dayBlocksInputSummaryForTest(input);
      expect(before, contains('ceilingReuse: 2 181.0'));
      expect(before, contains('napEdits: 1'));

      final port = ReceivePort();
      addTearDown(port.close);
      await expectIsolateRoundTrip<(SendPort, Object, SendPort?, int)>(
        (port.sendPort, input, null, 0),
        project: (r) => DerivationEngine.dayBlocksInputSummaryForTest(r.$2),
      );

      // And through the entry itself, on its real spawn path: the input goes in,
      // a _DayBlocksOutput comes back.
      final out = await DerivationEngine.runDayBlocksForTest(input);
      expect(out.runtimeType.toString(), '_DayBlocksOutput');
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
  'ecgFormatPageHeavy': (
    roundTrip: () async {
      // Raw sqlite rows (ints, text, NULLs, a BLOB) and the worker inputs in;
      // the text of the page out. The @SendableShape round trip itself is in
      // test/ecg_transparency/sendable_ecgFormatPageHeavy_test.dart.
      final rows = <Map<String, Object?>>[
        {'id': 'x', 'start_ts': 1, 'status': 'mystery', 'rms_uv': 1.5, 'v': null},
      ];
      final page = EcgRawPage(rows, [
        [
          {
            'sequence': 1,
            'samples': Uint8List.fromList([1, 0, 2, 0]),
            'inner_hex': '00',
            'is_placeholder': 0,
          },
        ],
      ]);
      const inputs = WorkerInputs(nowEpochMs: 1, zoneId: 'UTC', localeTag: 'en');
      await _sameInWorker(() => ecgFormatPageHeavy(inputs, page));
    },
  ),
  'decodeDayPayloadsHeavy': (
    roundTrip: () async {
      // Stored payload texts in; frozen compact graphs, node counts and byte
      // estimates out. The @SendableShape round trip (frozen graph arrives
      // frozen) is test/step2/sendable_decodeDayPayloadsHeavy_test.dart.
      const chunk = DecodeChunkInput(
        payloadJson: [
          '{"scalars":{"rhr":50.5},"series":{"hr_curve":{"t0":1,"dt":60,"v":[60,61,62]}}}',
          '{not json',
        ],
        projections: ['full', 'cycleScalars'],
      );
      await _sameInWorker(
        () => decodeDayPayloadsHeavy(bundleWorkerInputs, chunk),
        json: (DecodedChunk c) => [c.graphs, c.estimatedBytes, c.nodes],
      );
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
  'encodeSampleSignalsHeavy': (
    roundTrip: () async {
      // Per-signal slots (Float64List with NaN gaps) and resolved modes in; the
      // encoded parts out. Worker answer == direct answer, and the blobs equal
      // SampleCodec.encode (test/sample_archive/sendable_*_test.dart).
      final input = sampleEncodeInput();
      await expectIsolateRoundTrip<SampleEncodeInput>(input);
      await _sameInWorker(
          () => encodeSampleSignalsHeavy(sampleHeavyInputs, input),
          json: (Map<String, SampleEncodedPart> r) => [
                for (final e in r.entries)
                  [e.key, e.value.blob.toList(), e.value.nValid]
              ]);
    },
  ),
  'carveSamplePartHeavy': (
    roundTrip: () async {
      final input = sampleCarveInput();
      await expectIsolateRoundTrip<SampleCarveInput>(input);
      await _sameInWorker(() => carveSamplePartHeavy(sampleHeavyInputs, input),
          json: (SampleCarved? c) =>
              c == null ? null : [c.blob.toList(), c.nValid, c.rmsErr, c.maxErr]);
    },
  ),
  'reconstructSamplePartsHeavy': (
    roundTrip: () async {
      final input = sampleReconstructInput();
      await expectIsolateRoundTrip<SampleReconstructInput>(input);
      await _sameInWorker(
          () => reconstructSamplePartsHeavy(sampleHeavyInputs, input),
          json: (({int originSec, List<double?> samples}) r) =>
              [r.originSec, r.samples]);
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
