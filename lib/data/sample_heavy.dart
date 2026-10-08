// sample_heavy.dart — the sample archive's heavy work as registered @heavy worker
// entries (design 02). They replace three inline `Isolate.run` closures that the
// dispatcher audit could not see and the guard baselined as
// dispatcherClosureContract:
//   * [encodeSampleSignalsHeavy]    `SampleArchiver._archiveDevice` (encode),
//   * [reconstructSamplePartsHeavy] `SampleArchiver.reconstructWithOrigin`,
//   * [carveSamplePartHeavy]        `carveSamplePart` (sample_import.dart).
// Each is dispatched with `Isolate.run` (Dispatcher.run) under the labels
// 'sample encode', 'sample reconstruct' and 'sample carve'.
//
// The entries read no clock, zone or locale: parts are positional (absolute
// origin seconds), the caller resolves day labels and modes. [sampleWorkerInputs]
// is therefore a constant, not an ambient read.

import 'dart:typed_data';

import 'dart:math' as math;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';
import 'sample_codec.dart';
import 'sample_import.dart' show SampleCarved, carveSamplePartSync;

/// The inputs every sample entry is handed. No sample entry reads the clock, a
/// zone or a locale, so these are fixed rather than ambient.
const WorkerInputs sampleWorkerInputs =
    WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

/// One encoded signal: the blob and what its encode measured.
typedef SampleEncodedPart = ({
  Uint8List blob,
  int nValid,
  double rmsErr,
  double maxErr,
});

/// What [encodeSampleSignalsHeavy] reads: per signal, the slots to encode (one
/// per second, NaN = absent) and the codec mode already resolved by the caller.
@sendable
class SampleEncodeInput {
  const SampleEncodeInput({required this.slots, required this.modes});
  final Map<String, Float64List> slots;
  final Map<String, SampleMode> modes;
}

/// What [carveSamplePartHeavy] reads: a part and the minute cells already
/// covered (a list, not a Set: the sendable grammar has no Set).
@sendable
class SampleCarveInput {
  const SampleCarveInput({
    required this.blob,
    required this.coveredMinutes,
    required this.valid,
    required this.rmsErr,
    required this.maxErr,
  });
  final Uint8List blob;
  final List<int> coveredMinutes;
  final int valid;
  final double rmsErr;
  final double maxErr;
}

/// One stored part of a device-day signal: its absolute origin and blob.
@sendable
class SampleBlobPart {
  const SampleBlobPart(this.originSec, this.blob);
  final int originSec;
  final Uint8List blob;
}

/// What [reconstructSamplePartsHeavy] reads: the parts that hold samples and an
/// optional coarse order.
@sendable
class SampleReconstructInput {
  const SampleReconstructInput({required this.parts, this.maxOrder});
  final List<SampleBlobPart> parts;
  final int? maxOrder;
}

/// WORKER ENTRY: encodes each signal's slots with its mode (the loop that was
/// the `Isolate.run` closure in `SampleArchiver._archiveDevice`). NaN is absent.
@heavy
Map<String, SampleEncodedPart> encodeSampleSignalsHeavy(
    WorkerInputs inputs, SampleEncodeInput input) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('encodeSampleSignalsHeavy');
  final out = <String, SampleEncodedPart>{};
  for (final e in input.slots.entries) {
    final samples = <double?>[for (final v in e.value) v.isNaN ? null : v];
    final enc = SampleCodec.encode(e.key, samples,
        mode: input.modes[e.key] ?? SampleMode.pyramidOnly);
    out[e.key] = (
      blob: enc.blob,
      nValid: enc.stats.nValid,
      rmsErr: enc.stats.rmsErr,
      maxErr: enc.stats.maxErr,
    );
  }
  return out;
}

/// WORKER ENTRY: the carve of `carveSamplePartSync`, with the covered minutes
/// as a list. Null when nothing is kept.
@heavy
SampleCarved? carveSamplePartHeavy(
    WorkerInputs inputs, SampleCarveInput input) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('carveSamplePartHeavy');
  return carveSamplePartSync(
    input.blob,
    input.coveredMinutes.toSet(),
    valid: input.valid,
    rmsErr: input.rmsErr,
    maxErr: input.maxErr,
  );
}

/// WORKER ENTRY: decodes the parts and overlays them at their absolute origins
/// (the `Isolate.run` closure in `SampleArchiver.reconstructWithOrigin`). Later
/// parts overwrite earlier ones where both hold a sample; a slot no part holds
/// stays null.
@heavy
({int originSec, List<double?> samples}) reconstructSamplePartsHeavy(
    WorkerInputs inputs, SampleReconstructInput input) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('reconstructSamplePartsHeavy');
  final parts = input.parts;
  final maxOrder = input.maxOrder;
  final decoded = [
    for (final p in parts)
      maxOrder == null
          ? SampleCodec.decode(p.blob)
          : SampleCodec.decodeCoarse(p.blob, maxOrder: maxOrder)
  ];
  var o0 = parts.first.originSec, end = 0;
  for (var i = 0; i < parts.length; i++) {
    o0 = math.min(o0, parts[i].originSec);
    end = math.max(end, parts[i].originSec + decoded[i].length);
  }
  final out = List<double?>.filled(end - o0, null);
  for (var i = 0; i < parts.length; i++) {
    final base = parts[i].originSec - o0;
    final d = decoded[i];
    for (var j = 0; j < d.length; j++) {
      final v = d[j];
      if (v != null) out[base + j] = v;
    }
  }
  return (originSec: o0, samples: out);
}
