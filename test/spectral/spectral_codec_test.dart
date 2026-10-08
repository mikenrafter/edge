// SpectralCodec (RED): the pure block-DCT codec's contract. Every test fails
// today because the codec is a throwing stub.
//
// Signals are synthetic and seeded (test/support/spectral_fixtures.dart); no
// test reads a clock.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';

import '../support/spectral_fixtures.dart';

List<double?> _decode(SpectralEncoding e) => SpectralCodec.decode(e.blob);

/// Bounds hold, measured here independently of the codec's own stats.
void _expectWithin(String signal, List<double?> orig, List<double?> recon) {
  final spec = SpectralCodec.specs[signal]!;
  expect(recon.length, orig.length);
  final e = errorOf(orig, recon);
  expect(e.rms, lessThanOrEqualTo(spec.maxRms), reason: '$signal rms');
  expect(e.max, lessThanOrEqualTo(spec.maxAbs), reason: '$signal max');
}

void _expectMaskExact(List<double?> orig, List<double?> recon) {
  expect(recon.length, orig.length);
  for (var i = 0; i < orig.length; i++) {
    expect(recon[i] == null, orig[i] == null,
        reason: 'slot $i: absent must stay absent, present must stay present');
  }
}

void main() {
  group('bounds on synthetic shapes', () {
    test('a slow sine compresses to a handful of coefficients, within bounds',
        () {
      final s = List<double?>.generate(
          3600, (t) => 70 + 15 * math.sin(2 * math.pi * t / 1800));
      final e = SpectralCodec.encode('hr', s);
      _expectWithin('hr', s, _decode(e));
      expect(e.stats.coefficientCount * 20, lessThan(e.stats.nValid),
          reason: 'a pure low-frequency sine needs <5% of the coefficients');
    });

    test('a step 60 -> 140 -> 60 stays within bounds (no Gibbs overshoot '
        'beyond max); FINDING: on perfectly piecewise-constant data lossless '
        'delta+deflate is smaller (a step costs ~60 coefficients), so the only '
        'size claim is a sane ceiling', () {
      final s = List<double?>.generate(
          4000, (t) => (t >= 1000 && t < 2500) ? 140.0 : 60.0);
      final e = SpectralCodec.encode('hr', s);
      _expectWithin('hr', s, _decode(e));
      printOnFailure('step: spectral ${e.stats.bytes} B vs lossless '
          '${losslessBytes(s, 1.0)} B');
      expect(e.stats.bytes, lessThan(4000 * 8 ~/ 20)); // < 5% of 8 B/sample
    });

    test('white noise the transform cannot compress still honours the bound '
        '(it spends bytes, it never violates the contract)', () {
      final rnd = math.Random(99);
      final s = List<double?>.generate(
          2048, (_) => (70 + (rnd.nextDouble() - .5) * 40).roundToDouble());
      final e = SpectralCodec.encode('hr', s);
      _expectWithin('hr', s, _decode(e));
      expect(e.stats.maxErr, lessThanOrEqualTo(3.0));
    });

    test('sleep-like HR day with gaps: bounds hold and the mask is exact', () {
      final s = fixtureDay()['hr']!;
      final e = SpectralCodec.encode('hr', s);
      final d = _decode(e);
      _expectMaskExact(s, d);
      _expectWithin('hr', s, d);
    });

    for (final sig in ['hr', 'ax', 'ay', 'az', 'skin_temp_c']) {
      test('$sig: per-signal bound honoured on a full gapped day', () {
        final s = fixtureDay()[sig]!;
        final e = SpectralCodec.encode(sig, s);
        _expectWithin(sig, s, _decode(e));
        _expectMaskExact(s, _decode(e));
      });
    }

    test('the spec table is what the contract says', () {
      expect(SpectralCodec.specs.keys.toSet(),
          {'hr', 'ax', 'ay', 'az', 'skin_temp_c'});
      expect(SpectralCodec.specs['hr']!.maxRms, 1.0);
      expect(SpectralCodec.specs['hr']!.maxAbs, 3.0);
      for (final s in SpectralCodec.specs.values) {
        expect(s.blockSeconds, 240);
        expect(s.blockSeconds % 60, 0);
        expect(s.maxCoefficients, greaterThanOrEqualTo(60),
            reason: 'a one-minute segment must always be representable');
        // The quantizer alone must leave headroom under the bound, or no
        // coefficient count could ever satisfy it.
        expect(s.quantum, lessThan(s.maxRms));
      }
    });
  });

  group('gaps are absence, never data', () {
    test('all-null encodes to a valid blob and decodes all-null', () {
      final s = List<double?>.filled(1000, null);
      final e = SpectralCodec.encode('hr', s);
      expect(e.stats.nValid, 0);
      expect(e.stats.coefficientCount, 0);
      expect(_decode(e), s);
    });

    test('a lone valid sample in a sea of null, at a block edge', () {
      for (final at in [0, 255, 256, 511, 999]) {
        final s = List<double?>.filled(1000, null)..[at] = 77.0;
        final d = _decode(SpectralCodec.encode('hr', s));
        _expectMaskExact(s, d);
        expect((d[at]! - 77.0).abs(), lessThanOrEqualTo(3.0));
      }
    });

    test('leading, trailing and alternating nulls keep the exact mask', () {
      final lead = List<double?>.generate(900, (t) => t < 100 ? null : 70.0);
      final trail = List<double?>.generate(900, (t) => t > 800 ? null : 70.0);
      final alt = List<double?>.generate(900, (t) => t.isEven ? 65.0 : null);
      for (final s in [lead, trail, alt]) {
        _expectMaskExact(s, _decode(SpectralCodec.encode('hr', s)));
      }
    });

    test('nothing is interpolated across a gap: values only where valid, and '
        'a level shift across a gap is not smoothed into it', () {
      final s = List<double?>.generate(
          2000, (t) => (t >= 900 && t < 1100) ? null : (t < 1000 ? 60.0 : 130.0));
      final d = _decode(SpectralCodec.encode('hr', s));
      for (var t = 900; t < 1100; t++) {
        expect(d[t], isNull);
      }
      _expectWithin('hr', s, d);
    });

    test('stats.nValid counts exactly the non-null samples', () {
      final s = fixtureDay()['hr']!;
      final e = SpectralCodec.encode('hr', s);
      expect(e.stats.nValid, validCount(s));
      expect(e.stats.nSamples, s.length);
    });

    test('a DST-length day (23 h and 25 h) is not truncated or padded to '
        '86400', () {
      for (final len in [82800, 90000]) {
        final s = List<double?>.generate(
            len, (t) => t > len - 50 ? 80.0 : (t % 1000 < 20 ? null : 70.0));
        final d = _decode(SpectralCodec.encode('hr', s));
        expect(d.length, len);
        _expectMaskExact(s, d);
      }
    });
  });

  group('adaptive segmentation', () {
    List<double?> sine(int n) => List<double?>.generate(
        n, (t) => 70 + 15 * math.sin(2 * math.pi * t / 1800));

    test('segments tile the valid runs exactly: none spans a gap, none '
        'overlaps, none covers a null', () {
      final s = fixtureDay()['hr']!;
      final blob = SpectralCodec.encode('hr', s).blob;
      final segs = SpectralCodec.segments(blob);
      final covered = List<bool>.filled(s.length, false);
      for (final g in segs) {
        expect(g.length, greaterThan(0));
        for (var i = g.start; i < g.start + g.length; i++) {
          expect(s[i], isNotNull, reason: 'segment covers an absent slot $i');
          expect(covered[i], isFalse, reason: 'slot $i covered twice');
          covered[i] = true;
        }
      }
      for (var i = 0; i < s.length; i++) {
        expect(covered[i], s[i] != null, reason: 'slot $i');
      }
      expect(SpectralCodec.readHeader(blob).segmentCount, segs.length);
    });

    test('lengths are multiples of 60 s except the tail of a valid run', () {
      final s = fixtureDay()['hr']!;
      final segs = SpectralCodec.segments(SpectralCodec.encode('hr', s).blob);
      for (final g in segs) {
        final end = g.start + g.length;
        final runEnds = end == s.length || s[end] == null;
        if (!runEnds) {
          expect(g.length % 60, 0, reason: 'segment at ${g.start}');
        }
      }
    });

    test('every segment honours the coefficient cap AND the error bound '
        '(a segment closes rather than exceed either)', () {
      final s = fixtureDay()['hr']!;
      final e = SpectralCodec.encode('hr', s);
      final d = _decode(e);
      final spec = SpectralCodec.specs['hr']!;
      for (final g in SpectralCodec.segments(e.blob)) {
        expect(g.coefficientCount, lessThanOrEqualTo(spec.maxCoefficients));
        final o = s.sublist(g.start, g.start + g.length);
        final r = d.sublist(g.start, g.start + g.length);
        final err = errorOf(o, r);
        expect(err.rms, lessThanOrEqualTo(spec.maxRms), reason: '@${g.start}');
        expect(err.max, lessThanOrEqualTo(spec.maxAbs), reason: '@${g.start}');
      }
    });

    test('smooth data grows long segments; a step forces a split', () {
      final smooth = SpectralCodec.segments(
          SpectralCodec.encode('hr', sine(3600)).blob);
      expect(smooth.map((g) => g.length).reduce(math.max), greaterThan(900),
          reason: 'a slow sine fits in a long segment');
      final step = List<double?>.generate(3600, (t) => t < 1800 ? 60.0 : 140.0);
      final segs = SpectralCodec.segments(SpectralCodec.encode('hr', step).blob);
      expect(segs.where((g) => g.start < 1800 && g.start + g.length > 1800),
          isEmpty,
          reason: 'no segment may straddle the step (it would not fit the '
              'coefficient cap within the error allowance)');
    });

    test('incompressible noise closes at the 60 s minimum, bound still holds',
        () {
      final rnd = math.Random(4);
      final s = List<double?>.generate(
          1200, (_) => (70 + (rnd.nextDouble() - .5) * 60).roundToDouble());
      final e = SpectralCodec.encode('hr', s);
      _expectWithin('hr', s, _decode(e));
      for (final g in SpectralCodec.segments(e.blob)) {
        expect(g.length, lessThanOrEqualTo(120));
      }
    });

    test('fewer segments than static blocks on smooth data', () {
      final s = sine(7200);
      final a = SpectralCodec.encode('hr', s);
      final b = SpectralCodec.encode('hr', s, mode: SpectralMode.staticBlocks);
      expect(a.stats.segmentCount, lessThan(b.stats.segmentCount));
    });
  });

  group('static-block baseline mode', () {
    test('within bounds, mask exact, header says staticBlocks', () {
      final s = fixtureDay()['hr']!;
      final e = SpectralCodec.encode('hr', s, mode: SpectralMode.staticBlocks);
      final d = _decode(e);
      _expectMaskExact(s, d);
      _expectWithin('hr', s, d);
      expect(SpectralCodec.readHeader(e.blob).mode, SpectralMode.staticBlocks);
    });

    test('segments sit inside 240 s windows aligned to the day index and '
        'are clipped by gaps', () {
      final s = fixtureDay()['hr']!;
      final e = SpectralCodec.encode('hr', s, mode: SpectralMode.staticBlocks);
      for (final g in SpectralCodec.segments(e.blob)) {
        expect(g.start ~/ 240, (g.start + g.length - 1) ~/ 240,
            reason: 'segment @${g.start} crosses a block edge');
        for (var i = g.start; i < g.start + g.length; i++) {
          expect(s[i], isNotNull);
        }
      }
    });

    test('is deterministic and decodes on an isolate', () async {
      final s = fixtureDay()['skin_temp_c']!;
      final a = SpectralCodec.encode('skin_temp_c', s,
          mode: SpectralMode.staticBlocks).blob;
      final b = await Isolate.run(() => SpectralCodec.encode('skin_temp_c', s,
          mode: SpectralMode.staticBlocks).blob);
      expect(b, a);
    });
  });

  group('LOD: summary pyramid', () {
    // True per-cell stats straight from the raw samples.
    LodCell truth(List<double?> s, int from, int to) {
      final v = [for (var i = from; i < math.min(to, s.length); i++) if (s[i] != null) s[i]!];
      if (v.isEmpty) return const LodCell(0, null, null, null);
      return LodCell(v.length, v.reduce(math.min),
          v.reduce((a, b) => a + b) / v.length, v.reduce(math.max));
    }

    test('levels are 60 s, 900 s, 3600 s and one whole-series cell', () {
      for (final len in [kDay, 82800, 90000, 1000]) {
        final s = List<double?>.generate(len, (t) => 70.0 + (t ~/ 600) % 5);
        final lv = SpectralCodec.summary(SpectralCodec.encode('hr', s).blob);
        expect(lv.map((l) => l.cellSeconds), [60, 900, 3600, len]);
        expect(lv.last.cells, hasLength(1));
        for (final l in lv.take(3)) {
          expect(l.cells.length, (len / l.cellSeconds).ceil());
        }
      }
    });

    test('count, min, mean, max come from the RAW samples (hr: min/max are '
        'exactly the true extremes)', () {
      final s = fixtureDay()['hr']!;
      final lv = SpectralCodec.summary(SpectralCodec.encode('hr', s).blob);
      final q = SpectralCodec.specs['hr']!.quantum;
      for (final l in lv) {
        for (var i = 0; i < l.cells.length; i++) {
          final c = l.cells[i];
          final t = truth(s, i * l.cellSeconds, (i + 1) * l.cellSeconds);
          expect(c.count, t.count, reason: '${l.cellSeconds}s cell $i');
          if (t.count == 0) continue;
          expect(c.min, t.min, reason: 'min ${l.cellSeconds}s cell $i');
          expect(c.max, t.max, reason: 'max ${l.cellSeconds}s cell $i');
          expect((c.mean! - t.mean!).abs(), lessThanOrEqualTo(q / 2 + 1e-9),
              reason: 'mean ${l.cellSeconds}s cell $i');
        }
      }
    });

    test('a gap is honoured: an all-null cell has count 0 and NO stats', () {
      final s = List<double?>.generate(
          1800, (t) => (t >= 600 && t < 1500) ? null : 70.0);
      final lv = SpectralCodec.summary(SpectralCodec.encode('hr', s).blob);
      final minute = lv.first.cells;
      for (var i = 10; i < 25; i++) {
        expect(minute[i].count, 0);
        expect(minute[i].min, isNull);
        expect(minute[i].mean, isNull);
        expect(minute[i].max, isNull);
      }
      expect(minute[9].count, 60);
      expect(lv[1].cells[0].count, 600, reason: '0..899 holds 600 valid');
      expect(lv.last.cells.single.count, validCount(s));
    });

    test('a spike lost to lossy coding still shows in the true max, and the '
        'mean is the raw mean, not the approximation\'s', () {
      // 1-second +45 bpm spike: the bound (max err 3) forces the codec to keep
      // it, but the pyramid must not depend on that; it is raw by contract.
      final s = List<double?>.filled(600, 60.0)..[300] = 105.0;
      final lv = SpectralCodec.summary(SpectralCodec.encode('hr', s).blob);
      expect(lv.first.cells[5].max, 105.0);
      expect(lv.first.cells[5].min, 60.0);
      expect(lv.first.cells[5].mean, closeTo((59 * 60 + 105) / 60, 0.25));
    });

    test('levels agree with each other', () {
      final s = fixtureDay()['skin_temp_c']!;
      final lv = SpectralCodec.summary(SpectralCodec.encode('skin_temp_c', s).blob);
      final q = SpectralCodec.specs['skin_temp_c']!.quantum;
      for (var li = 1; li < lv.length; li++) {
        final fine = lv[li - 1], coarse = lv[li];
        for (var ci = 0; ci < coarse.cells.length; ci++) {
          final kids = [
            for (var k = 0; k < fine.cells.length; k++)
              if (k * fine.cellSeconds >= ci * coarse.cellSeconds &&
                  k * fine.cellSeconds < (ci + 1) * coarse.cellSeconds)
                fine.cells[k]
          ].where((c) => c.count > 0).toList();
          final c = coarse.cells[ci];
          expect(c.count, kids.fold<int>(0, (a, b) => a + b.count));
          if (kids.isEmpty) continue;
          expect(c.min, kids.map((k) => k.min!).reduce(math.min));
          expect(c.max, kids.map((k) => k.max!).reduce(math.max));
          final w = kids.fold<double>(0, (a, b) => a + b.mean! * b.count) / c.count;
          expect((c.mean! - w).abs(), lessThanOrEqualTo(q + 1e-9));
        }
      }
    });

    test('the pyramid is readable from the prefix before the first '
        'coefficient', () {
      final blob = SpectralCodec.encode('hr', fixtureDay()['hr']!).blob;
      final h = SpectralCodec.readHeader(blob);
      final prefix = Uint8List.sublistView(blob, 0, h.coefficientOffset);
      final a = SpectralCodec.summary(prefix);
      final b = SpectralCodec.summary(blob);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].cellSeconds, b[i].cellSeconds);
        expect([for (final c in a[i].cells) (c.count, c.min, c.mean, c.max)],
            [for (final c in b[i].cells) (c.count, c.min, c.mean, c.max)]);
      }
    });
  });

  group('LOD: coarse decode (low-order coefficients first)', () {
    test('never invents a value in a gap, at any order', () {
      final s = fixtureDay()['hr']!;
      final blob = SpectralCodec.encode('hr', s).blob;
      for (final order in [0, 1, 4, 16, 10000]) {
        _expectMaskExact(s, SpectralCodec.decodeCoarse(blob, maxOrder: order));
      }
    });

    test('order 0 is piecewise constant per segment and sits at the segment '
        'mean', () {
      final s = fixtureDay()['hr']!;
      final blob = SpectralCodec.encode('hr', s).blob;
      final c = SpectralCodec.decodeCoarse(blob, maxOrder: 0);
      final q = SpectralCodec.specs['hr']!.quantum;
      for (final g in SpectralCodec.segments(blob)) {
        final seg = c.sublist(g.start, g.start + g.length);
        expect(seg.toSet().length, 1, reason: 'constant in segment @${g.start}');
        final truthMean = s.sublist(g.start, g.start + g.length)
                .fold<double>(0, (a, b) => a + b!) / g.length;
        expect((seg.first! - truthMean).abs(), lessThanOrEqualTo(q));
      }
    });

    test('error never grows as more orders are read; enough orders equal the '
        'full decode', () {
      final s = fixtureDay()['hr']!;
      final blob = SpectralCodec.encode('hr', s).blob;
      final q = SpectralCodec.specs['hr']!.quantum;
      var prev = double.infinity;
      for (final order in [0, 2, 8, 32, 10000]) {
        final e = errorOf(s, SpectralCodec.decodeCoarse(blob, maxOrder: order));
        expect(e.rms, lessThanOrEqualTo(prev + q), reason: 'order $order');
        prev = e.rms;
      }
      expect(SpectralCodec.decodeCoarse(blob, maxOrder: 10000),
          SpectralCodec.decode(blob));
    });
  });

  group('stats are honest', () {
    test('rmsErr / maxErr / bytes equal what an independent decode measures',
        () {
      final s = fixtureDay()['skin_temp_c']!;
      final e = SpectralCodec.encode('skin_temp_c', s);
      final m = errorOf(s, _decode(e));
      expect(e.stats.rmsErr, closeTo(m.rms, 1e-9));
      expect(e.stats.maxErr, closeTo(m.max, 1e-9));
      expect(e.stats.bytes, e.blob.length);
      expect(e.stats.segmentCount, SpectralCodec.segments(e.blob).length);
      expect(e.stats.summaryBytes, greaterThan(0));
      expect(e.stats.summaryBytes, lessThan(e.stats.bytes));
    });
  });

  group('determinism and isolates', () {
    test('same input, byte-identical blob, twice', () {
      final s = fixtureDay()['hr']!;
      final a = SpectralCodec.encode('hr', s).blob;
      final b = SpectralCodec.encode('hr', List<double?>.of(s)).blob;
      expect(a, b);
    });

    test('encode on a worker isolate gives the same bytes and decode agrees',
        () async {
      final s = fixtureDay()['ax']!;
      final here = SpectralCodec.encode('ax', s).blob;
      final there = await Isolate.run(() => SpectralCodec.encode('ax', s).blob);
      expect(there, here);
      final d = await Isolate.run(() => SpectralCodec.decode(here));
      expect(d, SpectralCodec.decode(here));
    });
  });

  group('versioned header', () {
    test('carries codec version, block size, quantizer step, signal id, length '
        'and valid count', () {
      final s = fixtureDay()['ay']!;
      final blob = SpectralCodec.encode('ay', s).blob;
      final h = SpectralCodec.readHeader(blob);
      final spec = SpectralCodec.specs['ay']!;
      expect(h.codecVersion, SpectralCodec.codecVersion);
      expect(h.codecVersion, 1);
      expect(h.signal, 'ay');
      expect(h.blockSeconds, spec.blockSeconds);
      expect(h.mode, SpectralMode.adaptive);
      expect(h.segmentCount, SpectralCodec.segments(blob).length);
      expect(h.coefficientOffset, greaterThan(0));
      expect(h.coefficientOffset, lessThan(blob.length));
      expect(h.quantum, spec.quantum);
      expect(h.length, s.length);
      expect(h.nValid, validCount(s));
    });

    test('an unknown codec version is refused, never guessed at', () {
      final blob = SpectralCodec.encode('hr', [70.0, 71.0, 72.0]).blob;
      // Find the version by comparing against a re-stamped copy: bump every
      // byte in the first 8 in turn until readHeader reports a different
      // version, then assert decode refuses that blob.
      Uint8List? stamped;
      for (var i = 0; i < 8 && stamped == null; i++) {
        final c = Uint8List.fromList(blob)..[i] = blob[i] + 1;
        try {
          if (SpectralCodec.readHeader(c).codecVersion != 1) stamped = c;
        } on FormatException {
          // that byte was the magic, keep looking
        }
      }
      expect(stamped, isNotNull, reason: 'a version field in the first 8 bytes');
      expect(() => SpectralCodec.decode(stamped!),
          throwsA(isA<FormatException>()));
    });

    test('bad magic and a truncated body are FormatException', () {
      final blob = SpectralCodec.encode('hr', fixtureDay()['hr']!).blob;
      expect(() => SpectralCodec.decode(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<FormatException>()));
      expect(() => SpectralCodec.decode(Uint8List(0)),
          throwsA(isA<FormatException>()));
      expect(
          () => SpectralCodec.decode(
              Uint8List.sublistView(blob, 0, blob.length ~/ 2)),
          throwsA(isA<FormatException>()));
    });
  });

  group('refusals', () {
    test('an unknown signal id is an ArgumentError', () {
      expect(() => SpectralCodec.encode('step_count', [1.0, 2.0]),
          throwsArgumentError);
    });

    test('NaN and infinity are not "absent": refused, not stored', () {
      expect(() => SpectralCodec.encode('hr', [70.0, double.nan]),
          throwsArgumentError);
      expect(() => SpectralCodec.encode('hr', [70.0, double.infinity]),
          throwsArgumentError);
    });
  });

  group('size budget (bytes per day) - tune in one place', () {
    // Guesses to be replaced by the experiment's numbers; the point is that a
    // budget exists and a regression fails. Raw `decoded_onehz` is ~12 MB/day.
    const hrBudget = 24 * 1024;
    const dayBudget = 96 * 1024;
    const pyramidBudget = 8 * 1024; // per signal-day, included in the above

    test('a full gapped HR day fits $hrBudget bytes', () {
      final e = SpectralCodec.encode('hr', fixtureDay()['hr']!);
      printOnFailure('hr day: ${e.stats.bytes} B, coeffs ${e.stats.coefficientCount}');
      expect(e.stats.bytes, lessThanOrEqualTo(hrBudget));
    });

    test('the summary pyramid costs at most $pyramidBudget bytes per signal '
        'per day', () {
      fixtureDay().forEach((sig, s) {
        final b = SpectralCodec.encode(sig, s).stats.summaryBytes;
        printOnFailure('$sig pyramid: $b B');
        expect(b, lessThanOrEqualTo(pyramidBudget), reason: sig);
      });
    });

    test('all five signals of a day fit $dayBudget bytes together', () {
      var total = 0;
      fixtureDay().forEach((sig, s) {
        final b = SpectralCodec.encode(sig, s).stats.bytes;
        printOnFailure('$sig: $b B');
        total += b;
      });
      expect(total, lessThanOrEqualTo(dayBudget));
    });
  });
}
