// The spectral-archive EXPERIMENT HARNESS (RED until the codec exists).
//
// Runs both codec segmentations (adaptive and 240 s static blocks) plus the two
// baselines (lossless = deflate of zigzag deltas; keep-every-Nth with linear
// interpolation) over the fixture day for every archived signal, and prints one
// table so the owner can judge:
//
//   signal  valid  lossless  every-N  static  adaptive  segments  rms/max  pyramid
//
//   TZ=UTC flutter test test/spectral/spectral_experiment_test.dart
//
// The fixtures are SYNTHETIC (no real 1 Hz day exists in test/): the numbers
// say how the codec behaves on plausible shapes, not what a real week costs.
// Re-run it on an exported day before believing a ratio. A `whiteNoiseAccel`
// row (the repo's own synthAccel generator) is the worst case, reported but not
// asserted.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';

import '../support/spectral_fixtures.dart';

void main() {
  final day = fixtureDay();
  final rows = <String>[];

  tearDownAll(() {
    // ignore: avoid_print
    print('\n=== spectral archive experiment (bytes per signal-day) ===\n'
        '${rows.join('\n')}\n');
  });

  for (final sig in day.keys) {
    test('$sig: both modes meet the bound; table row reported', () {
      final s = day[sig]!;
      final spec = SpectralCodec.specs[sig]!;
      final a = SpectralCodec.encode(sig, s);
      final b = SpectralCodec.encode(sig, s, mode: SpectralMode.staticBlocks);
      for (final e in [a, b]) {
        final m = errorOf(s, SpectralCodec.decode(e.blob));
        expect(m.rms, lessThanOrEqualTo(spec.maxRms));
        expect(m.max, lessThanOrEqualTo(spec.maxAbs));
      }
      final lossless = losslessBytes(s, spec.quantum);
      final nth = keepEveryNth(s, spec.quantum, spec.maxRms, spec.maxAbs);
      rows.add(fmtRow(sig, validCount(s), lossless, nth.n, nth.bytes, a.stats));
      rows.add('  static-240s  spectral=${b.stats.bytes}B '
          'segments=${b.stats.segmentCount} '
          'rms=${b.stats.rmsErr.toStringAsFixed(3)} '
          'max=${b.stats.maxErr.toStringAsFixed(3)} '
          'pyramid=${b.stats.summaryBytes}B');
      rows.add('  adaptive     spectral=${a.stats.bytes}B '
          'segments=${a.stats.segmentCount} '
          'rms=${a.stats.rmsErr.toStringAsFixed(3)} '
          'max=${a.stats.maxErr.toStringAsFixed(3)} '
          'pyramid=${a.stats.summaryBytes}B');
      // Report the data: if this ever fails the premise is wrong, and that is
      // a finding, not a flake.
      if (sig == 'hr' || sig == 'skin_temp_c') {
        expect(a.stats.bytes, lessThan(lossless),
            reason: 'the premise: lossy beats lossless on a smooth signal');
        expect(a.stats.bytes, lessThanOrEqualTo(nth.bytes),
            reason: 'the premise: DCT beats keep-every-Nth at equal error');
        expect(a.stats.bytes, lessThanOrEqualTo((b.stats.bytes * 1.05).ceil()),
            reason: 'the owner hypothesis: adaptive segments cost no more '
                'than static 240 s blocks');
      }
    });
  }

  test('worst case (reported, not asserted on size): the repo\'s own '
      'white-noise synthAccel, bound still holds', () {
    final s = withGaps(whiteNoiseAccel(0), 9);
    final spec = SpectralCodec.specs['ax']!;
    final e = SpectralCodec.encode('ax', s);
    final m = errorOf(s, SpectralCodec.decode(e.blob));
    expect(m.rms, lessThanOrEqualTo(spec.maxRms));
    expect(m.max, lessThanOrEqualTo(spec.maxAbs));
    rows.add('worst-case ax (white noise while moving): '
        'lossless=${losslessBytes(s, spec.quantum)}B spectral=${e.stats.bytes}B '
        'segments=${e.stats.segmentCount}');
  });

  test('five signals together: bytes/day for adaptive vs static', () {
    var ad = 0, st = 0;
    day.forEach((sig, s) {
      ad += SpectralCodec.encode(sig, s).stats.bytes;
      st += SpectralCodec.encode(sig, s, mode: SpectralMode.staticBlocks)
          .stats.bytes;
    });
    rows.add('TOTAL/day  adaptive=${ad}B  static-240s=${st}B');
    expect(ad, greaterThan(0));
  });
}
