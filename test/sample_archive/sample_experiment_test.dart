// The sample-archive EXPERIMENT HARNESS (RED until the codec exists).
//
// Runs both codec segmentations (adaptive and 240 s static blocks) plus the two
// baselines (lossless = deflate of zigzag deltas; keep-every-Nth with linear
// interpolation) over the fixture day for every archived signal, and prints one
// table so the owner can judge:
//
//   signal  valid  lossless  every-N  static  adaptive  segments  rms/max  pyramid
//
//   TZ=UTC flutter test test/sample/sample_experiment_test.dart
//
// The fixtures are SYNTHETIC (no real 1 Hz day exists in test/): the numbers
// say how the codec behaves on plausible shapes, not what a real week costs.
// Re-run it on an exported day before believing a ratio. A `whiteNoiseAccel`
// row (the repo's own synthAccel generator) is the worst case, reported but not
// asserted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sample_codec.dart';

import '../support/sample_fixtures.dart';

void main() {
  final day = fixtureDay();
  final rows = <String>[];

  tearDownAll(() {
    final report = '=== sample archive experiment (bytes per signal-day) ===\n'
        '${rows.join('\n')}\n';
    // Also to a file the owner can open: build/sample_experiment.txt.
    Directory('build').createSync(recursive: true);
    File('build/sample_experiment.txt').writeAsStringSync(report);
    // ignore: avoid_print
    print('\n$report');
  });

  for (final sig in day.keys) {
    test('$sig: both modes meet the bound; table row reported', () {
      final s = day[sig]!;
      final spec = SampleCodec.specs[sig]!;
      final a = SampleCodec.encode(sig, s);
      final b = SampleCodec.encode(sig, s, mode: SampleMode.staticBlocks);
      for (final e in [a, b]) {
        final m = errorOf(s, SampleCodec.decode(e.blob));
        expect(m.rms, lessThanOrEqualTo(spec.maxRms));
        expect(m.max, lessThanOrEqualTo(spec.maxAbs));
      }
      final lossless = losslessBytes(s, spec.quantum);
      final nth = keepEveryNth(s, spec.quantum, spec.maxRms, spec.maxAbs);
      rows.add(fmtRow(sig, validCount(s), lossless, nth.n, nth.bytes, a.stats));
      rows.add('  static-240s  sample=${b.stats.bytes}B '
          'segments=${b.stats.segmentCount} '
          'rms=${b.stats.rmsErr.toStringAsFixed(3)} '
          'max=${b.stats.maxErr.toStringAsFixed(3)} '
          'pyramid=${b.stats.summaryBytes}B');
      rows.add('  adaptive     sample=${a.stats.bytes}B '
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
    final spec = SampleCodec.specs['ax']!;
    final e = SampleCodec.encode('ax', s);
    final m = errorOf(s, SampleCodec.decode(e.blob));
    expect(m.rms, lessThanOrEqualTo(spec.maxRms));
    expect(m.max, lessThanOrEqualTo(spec.maxAbs));
    rows.add('worst-case ax (white noise while moving): '
        'lossless=${losslessBytes(s, spec.quantum)}B sample=${e.stats.bytes}B '
        'segments=${e.stats.segmentCount}');
  });

  test('harder case (reported, not asserted on size): broadband HR with '
      'coloured beat-to-beat variability, bound still holds', () {
    final s = withGaps(broadbandHr(), 21);
    final spec = SampleCodec.specs['hr']!;
    final a = SampleCodec.encode('hr', s);
    final b = SampleCodec.encode('hr', s, mode: SampleMode.staticBlocks);
    final m = errorOf(s, SampleCodec.decode(a.blob));
    expect(m.rms, lessThanOrEqualTo(spec.maxRms));
    expect(m.max, lessThanOrEqualTo(spec.maxAbs));
    final nth = keepEveryNth(s, spec.quantum, spec.maxRms, spec.maxAbs);
    rows.add('broadband hr (AR(1) variability, no pure sinusoid): '
        'lossless=${losslessBytes(s, spec.quantum)}B every-${nth.n}=${nth.bytes}B '
        'adaptive=${a.stats.bytes}B (segments=${a.stats.segmentCount}, '
        'rms=${a.stats.rmsErr.toStringAsFixed(3)}, '
        'max=${a.stats.maxErr.toStringAsFixed(3)}) '
        'static-240s=${b.stats.bytes}B (segments=${b.stats.segmentCount})');
  });

  test('accelerometer options on the synthetic fixture (reported): lossless '
      'at the 0.004 g quantum vs pyramid-only vs lossy DCT', () {
    var ll = 0, py = 0, dct = 0;
    for (final sig in ['ax', 'ay', 'az']) {
      final s = day[sig]!;
      final spec = SampleCodec.specs[sig]!;
      final a = SampleCodec.encode(sig, s, mode: SampleMode.losslessAtQuantum);
      final b = SampleCodec.encode(sig, s, mode: SampleMode.pyramidOnly);
      final c = SampleCodec.encode(sig, s);
      final back = SampleCodec.decode(a.blob);
      for (var i = 0; i < s.length; i++) {
        expect(back[i], s[i] == null ? isNull : (s[i]! / spec.quantum).round() * spec.quantum);
      }
      expect(b.stats.bytes, lessThan(a.stats.bytes));
      ll += a.stats.bytes;
      py += b.stats.bytes;
      dct += c.stats.bytes;
    }
    final hr = SampleCodec.encode('hr', day['hr']!).stats.bytes;
    final temp = SampleCodec.encode('skin_temp_c', day['skin_temp_c']!).stats.bytes;
    rows.add('accel (ax+ay+az), synthetic: lossless-at-q=${ll}B  '
        'pyramid-only=${py}B  lossy-DCT=${dct}B');
    rows.add('TOTAL/day synthetic: hr ${hr}B + temp ${temp}B + accel lossless '
        '${ll}B = ${hr + temp + ll}B | with accel pyramid-only ${py}B = '
        '${hr + temp + py}B');
  });

  test('five signals together: bytes/day for adaptive vs static', () {
    var ad = 0, st = 0;
    day.forEach((sig, s) {
      ad += SampleCodec.encode(sig, s).stats.bytes;
      st += SampleCodec.encode(sig, s, mode: SampleMode.staticBlocks)
          .stats.bytes;
    });
    rows.add('TOTAL/day  adaptive=${ad}B  static-240s=${st}B');
    expect(ad, greaterThan(0));
  });
}
