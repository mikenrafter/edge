// Sample archive, round 6 A (RED): the lossy DCT is replaced for hr and skin
// temperature by plain quantize + zigzag-delta + deflate.
//
//   * exact per-sample bound step/2, stored as the part's max error; rms
//     measured from the actual samples at encode time
//   * the step lives in the (version 2) header; the pyramid keeps its own,
//     finer quantum
//   * version-1 (DCT) blobs still read, and are never silently re-encoded
//   * progressive loading: one full step for the new codec, the DCT ladder for
//     old parts
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';

import '../support/sample_fixtures.dart';
import '../support/sample_v1_blobs.dart';

const _hrStep = 2.8;
const _tempStep = 0.12;

double _step(String sig) => sig == 'hr' ? _hrStep : _tempStep;

({double rms, double max}) _err(List<double?> a, List<double?> b) {
  var sq = 0.0, mx = 0.0, n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == null) {
      expect(b[i], isNull, reason: 'a gap stays a gap at $i');
      continue;
    }
    final d = (a[i]! - b[i]!).abs();
    sq += d * d;
    mx = math.max(mx, d);
    n++;
  }
  return (rms: n == 0 ? 0 : math.sqrt(sq / n), max: mx);
}

void main() {
  group('A: quantized mode, hr and skin temperature', () {
    final cases = <String, List<double?>>{
      'hr sleepLike': sleepLikeHr(),
      'hr broadband gaps': withGaps(broadbandHr(), 4),
      'hr extremes': [
        for (var i = 0; i < 3000; i++)
          [1.0, 255.0, 30.0, 71.4, 71.3, 74.2, 0.4, 199.99, null][i % 9]
      ],
      'skin_temp_c': skinTemp(),
      'skin_temp_c gaps': withGaps(skinTemp(), 9),
      'skin_temp_c extremes': [
        for (var i = 0; i < 3000; i++)
          [20.0, 42.06, 33.33, 35.01, 35.0, 34.99, null][i % 7]
      ],
    };
    for (final e in cases.entries) {
      final sig = e.key.startsWith('hr') ? 'hr' : 'skin_temp_c';
      test('${e.key}: |err| <= step/2 per sample, nulls kept, max stat is '
          'step/2, rms is measured', () {
        final enc = SampleCodec.encode(sig, e.value,
            mode: SampleMode.quantized);
        final back = SampleCodec.decode(enc.blob);
        expect(back.length, e.value.length);
        final m = _err(e.value, back);
        expect(m.max, lessThanOrEqualTo(_step(sig) / 2 + 1e-9));
        expect(enc.stats.maxErr, closeTo(_step(sig) / 2, 1e-12));
        expect(enc.stats.rmsErr, closeTo(m.rms, 1e-9));
        expect(enc.stats.nValid, e.value.where((v) => v != null).length);
        // decoded values are exact multiples of the step.
        for (final v in back.whereType<double>()) {
          expect(((v / _step(sig)) - (v / _step(sig)).round()).abs(),
              lessThan(1e-9));
        }
      });
    }

    test('header round-trip: version 2, mode, step, pyramid quantum, length',
        () {
      final s = withGaps(sleepLikeHr(), 3);
      final enc = SampleCodec.encode('hr', s, mode: SampleMode.quantized);
      final h = SampleCodec.readHeader(enc.blob);
      expect(SampleCodec.codecVersion, 2);
      expect(h.codecVersion, 2);
      expect(h.mode, SampleMode.quantized);
      expect(h.step, _hrStep);
      expect(h.quantum, 0.5, reason: 'the pyramid keeps its finer quantum');
      expect(h.signal, 'hr');
      expect(h.length, s.length);
      expect(h.nValid, s.where((v) => v != null).length);
      final t = SampleCodec.readHeader(SampleCodec.encode(
              'skin_temp_c', skinTemp(),
              mode: SampleMode.quantized)
          .blob);
      expect(t.step, _tempStep);
      expect(t.quantum, 0.01);
      // other modes: step is their quantum.
      final l = SampleCodec.readHeader(SampleCodec.encode('ax', [0.3, 0.4],
              mode: SampleMode.losslessAtQuantum)
          .blob);
      expect(l.step, l.quantum);
    });

    test('the pyramid is NOT coarsened to the step', () {
      final s = [for (var i = 0; i < 600; i++) 71.3];
      final enc = SampleCodec.encode('hr', s, mode: SampleMode.quantized);
      final c = SampleCodec.summary(enc.blob).first.cells.first;
      expect([c.min, c.mean, c.max], [71.5, 71.5, 71.5],
          reason: 'true value rounded at 0.5, not at 2.8');
      expect(SampleCodec.decode(enc.blob).first, closeTo(70.0, 1e-9),
          reason: 'the samples are on the 2.8 grid: round(71.3 / 2.8) = 25');
    });

    test('quantized needs a step: accelerometer signals refuse it', () {
      expect(
          () => SampleCodec.encode('ax', [0.3], mode: SampleMode.quantized),
          throwsArgumentError);
    });

    test('size sanity: never larger than lossless at the pyramid quantum, on '
        'the synthetic fixtures', () {
      final sets = <String, List<double?>>{
        'hr': sleepLikeHr(),
        'hr ': withGaps(broadbandHr(), 5),
        'skin_temp_c': skinTemp(),
        'skin_temp_c ': withGaps(skinTemp(), 6),
      };
      for (final e in sets.entries) {
        final sig = e.key.trim();
        final q = SampleCodec.encode(sig, e.value,
            mode: SampleMode.quantized);
        final l = SampleCodec.encode(sig, e.value,
            mode: SampleMode.losslessAtQuantum);
        expect(q.blob.length, lessThanOrEqualTo(l.blob.length),
            reason: '${e.key}: ${q.blob.length} vs lossless ${l.blob.length}');
      }
    });

    test('the archiver defaults: hr and skin temp quantized, accel '
        'pyramid-only', () {
      expect(SampleArchiver.defaultModes['hr'], SampleMode.quantized);
      expect(SampleArchiver.defaultModes['skin_temp_c'],
          SampleMode.quantized);
      for (final a in ['ax', 'ay', 'az']) {
        expect(SampleArchiver.defaultModes[a], SampleMode.pyramidOnly);
      }
    });

    test('a quantized part is not exact, and a carve keeps its bound '
        '(requantising multiples of the step adds no error)', () {
      final s = withGaps(sleepLikeHr(), 8);
      final enc = SampleCodec.encode('hr', s, mode: SampleMode.quantized);
      final out = SampleCodec.restrict(enc.blob, (m) => m.isEven)!;
      expect(out.stats.maxErr, 0, reason: 'measured vs the decoded part');
      final a = SampleCodec.decode(enc.blob);
      final b = SampleCodec.decode(out.blob);
      for (var i = 0; i < a.length; i++) {
        if (b[i] != null) expect(b[i], a[i]);
      }
      expect(SampleCodec.readHeader(out.blob).mode, SampleMode.quantized);
      expect(SampleCodec.readHeader(out.blob).step, _hrStep);
    });
  });

  group('A: version-1 (DCT) parts still read, and are never re-encoded', () {
    test('every frozen v1 blob decodes to what it decoded to when written',
        () {
      for (final f in [v1HrAdaptive, v1HrStatic, v1AxLossless]) {
        final b = f.bytes;
        final h = SampleCodec.readHeader(b);
        expect(h.codecVersion, 1);
        expect(h.step, h.quantum, reason: 'no step field before v2');
        final d = SampleCodec.decode(b);
        expect(d.length, 400);
        var sum = 0.0;
        for (final v in d) {
          if (v != null) sum += v;
        }
        expect(sum, closeTo(f.sum, 1e-5));
        final at = [0, 1, 129, 160, 399];
        for (var k = 0; k < at.length; k++) {
          expect(d[at[k]], closeTo(f.probes![k], 1e-5));
        }
        for (var i = 130; i < 160; i++) {
          expect(d[i], isNull);
        }
        expect(SampleCodec.validRuns(b), [(0, 130), (160, 400)]);
        expect(SampleCodec.summary(b).first.cells.length, 7);
      }
      expect(SampleCodec.readHeader(v1HrAdaptive.bytes).mode,
          SampleMode.adaptive);
      expect(SampleCodec.readHeader(v1AxLossless.bytes).mode,
          SampleMode.losslessAtQuantum);
    });

    test('a v1 pyramid-only blob still gives its pyramid', () {
      final b = v1AxPyramid.bytes;
      expect(SampleCodec.hasSamples(b), isFalse);
      expect(SampleCodec.summary(b).last.cells.single.count, 370);
    });

    test('restrict refuses a v1 part: carving would re-encode it silently',
        () {
      expect(() => SampleCodec.restrict(v1HrAdaptive.bytes, (_) => true),
          throwsFormatException);
      expect(() => SampleCodec.restrict(v1AxLossless.bytes, (_) => true),
          throwsFormatException);
    });

    test('an unknown version is still refused', () {
      final b = Uint8List.fromList(v1HrAdaptive.bytes)..[4] = 9;
      expect(() => SampleCodec.decode(b), throwsFormatException);
    });
  });

  group('A: progressive loading', () {
    test('a quantized part has no coefficient ladder: one full step; the '
        'pyramid is available without decoding', () {
      final enc = SampleCodec.encode('hr', sleepLikeHr(length: 3600),
          mode: SampleMode.quantized);
      final steps = SampleCodec.progressive(enc.blob).toList();
      expect(steps, hasLength(1));
      expect(steps.single.isFull, isTrue);
      expect(steps.single.samples, SampleCodec.decode(enc.blob));
      expect(SampleCodec.decodeCoarse(enc.blob, maxOrder: 0),
          SampleCodec.decode(enc.blob));
      expect(SampleCodec.summary(enc.blob).first.cells.length, 60);
    });

    test('an old DCT part still refines in several steps', () {
      final steps = SampleCodec.progressive(v1HrAdaptive.bytes).toList();
      expect(steps.length, greaterThan(1));
      expect(steps.last.isFull, isTrue);
      expect(steps.last.samples, SampleCodec.decode(v1HrAdaptive.bytes));
    });
  });
}
