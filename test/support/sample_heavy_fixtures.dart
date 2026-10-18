// Inputs for the sample archive's registered @heavy entries
// (lib/data/sample_heavy.dart) and the ORACLES they must match byte for byte:
// the code the entries replace (`SampleCodec.encode`, `carveSamplePartSync`,
// the decode + overlay of `SampleArchiver.reconstructWithOrigin`). Seeded, no
// clock.
import 'dart:typed_data';

import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'sample_fixtures.dart';

const sampleHeavyInputs =
    WorkerInputs(nowEpochMs: 1791000000000, zoneId: 'UTC', localeTag: 'en');

/// Ten minutes of the fixture day (gaps included), NaN = absent.
const _slots = 600;

/// The modes `SampleArchiver.defaultModes` gives these signals.
const _modes = <String, SampleMode>{
  'hr': SampleMode.quantized,
  'ax': SampleMode.pyramidOnly,
  'skin_temp_c': SampleMode.quantized,
};

SampleEncodeInput sampleEncodeInput() {
  final day = fixtureDay();
  return SampleEncodeInput(
    slots: {
      for (final s in _modes.keys)
        s: Float64List.fromList(
            [for (var i = 0; i < _slots; i++) day[s]![i] ?? double.nan]),
    },
    modes: Map.of(_modes),
  );
}

/// What the `Isolate.run` closure in `_archiveDevice` computes today.
Map<String, SampleEncodedPart> sampleEncodeOracle(SampleEncodeInput input) {
  final out = <String, SampleEncodedPart>{};
  for (final e in input.slots.entries) {
    final samples = <double?>[for (final v in e.value) v.isNaN ? null : v];
    final enc = SampleCodec.encode(e.key, samples, mode: input.modes[e.key]!);
    out[e.key] = (
      blob: enc.blob,
      nValid: enc.stats.nValid,
      rmsErr: enc.stats.rmsErr,
      maxErr: enc.stats.maxErr,
    );
  }
  return out;
}

/// An incoming hr part covering slots 0-359 (six minutes), minutes 0-3 covered.
SampleCarveInput sampleCarveInput() {
  final series = <double?>[
    for (var i = 0; i < 360; i++) 80.0 + (i % 7),
  ];
  return SampleCarveInput(
    blob: SampleCodec.encode('hr', series).blob,
    coveredMinutes: const [0, 1, 2, 3],
    valid: 360,
    rmsErr: 0.5,
    maxErr: 2.0,
  );
}

/// Two hr parts of one device-day, the second starting 300 s after the first and
/// overlapping it by 100 s.
SampleReconstructInput sampleReconstructInput({int? maxOrder}) {
  List<double?> part(int n, double base) =>
      [for (var i = 0; i < n; i++) base + (i % 5)];
  return SampleReconstructInput(
    parts: [
      SampleBlobPart(1790000000,
          SampleCodec.encode('hr', part(600, 60), mode: SampleMode.quantized).blob),
      SampleBlobPart(1790000300,
          SampleCodec.encode('hr', part(600, 90), mode: SampleMode.quantized).blob),
    ],
    maxOrder: maxOrder,
  );
}

/// The decode + overlay `SampleArchiver.reconstructWithOrigin` runs today, with
/// later parts overwriting earlier ones where both hold a sample.
({int originSec, List<double?> samples}) sampleReconstructOracle(
    SampleReconstructInput input) {
  final decoded = [
    for (final p in input.parts)
      input.maxOrder == null
          ? SampleCodec.decode(p.blob)
          : SampleCodec.decodeCoarse(p.blob, maxOrder: input.maxOrder!)
  ];
  var o0 = input.parts.first.originSec, end = 0;
  for (var i = 0; i < input.parts.length; i++) {
    if (input.parts[i].originSec < o0) o0 = input.parts[i].originSec;
    final e = input.parts[i].originSec + decoded[i].length;
    if (e > end) end = e;
  }
  final out = List<double?>.filled(end - o0, null);
  for (var i = 0; i < input.parts.length; i++) {
    final base = input.parts[i].originSec - o0;
    for (var j = 0; j < decoded[i].length; j++) {
      final v = decoded[i][j];
      if (v != null) out[base + j] = v;
    }
  }
  return (originSec: o0, samples: out);
}
