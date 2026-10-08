// sample_heavy.dart — RED STUB (design 02 follow-up 3): the sample archive's
// encode / carve / reconstruct work as registered @heavy worker entries.
//
// Nothing here is implemented or registered yet. The tests in
// test/sample_archive/sendable_*Heavy_test.dart, sample_heavy_entries_test.dart,
// test/guards/worker_registry_test.dart and background_dispatch_audit_test.dart
// pin the contract; GREEN moves the bodies of the three `Isolate.run` closures in
// sample_archive.dart / sample_import.dart here, registers them in
// `kWorkerEntries` (all `Dispatcher.run`) and dispatches them with
// `WorkerAudit.dispatched` labels 'sample encode', 'sample carve' and
// 'sample reconstruct'.

import 'dart:typed_data';

import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'sample_codec.dart';
import 'sample_import.dart' show SampleCarved;

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
/// the `Isolate.run` closure in `SampleArchiver._archiveDevice`).
@heavy
Map<String, SampleEncodedPart> encodeSampleSignalsHeavy(
    WorkerInputs inputs, SampleEncodeInput input) {
  throw UnimplementedError('encodeSampleSignalsHeavy');
}

/// WORKER ENTRY: the carve of `carveSamplePartSync`, with the covered minutes
/// as a list. Null when nothing is kept.
@heavy
SampleCarved? carveSamplePartHeavy(
    WorkerInputs inputs, SampleCarveInput input) {
  throw UnimplementedError('carveSamplePartHeavy');
}

/// WORKER ENTRY: decodes the parts and overlays them at their absolute origins
/// (the `Isolate.run` closure in `SampleArchiver.reconstructWithOrigin`).
@heavy
({int originSec, List<double?> samples}) reconstructSamplePartsHeavy(
    WorkerInputs inputs, SampleReconstructInput input) {
  throw UnimplementedError('reconstructSamplePartsHeavy');
}
