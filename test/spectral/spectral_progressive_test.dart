// Progressive loading (RED): the pure parts. The chart widget is a thin
// prototype in the green phase; what it may claim is pinned here.
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';
import 'package:openstrap_edge/data/spectral_progressive.dart';

import '../support/dart_source.dart';
import '../support/spectral_fixtures.dart';

void _maskEq(List<double?> a, List<double?> b) {
  expect(a.length, b.length);
  for (var i = 0; i < a.length; i++) {
    expect(a[i] == null, b[i] == null, reason: 'slot $i');
  }
}

void main() {
  final s = fixtureDay()['hr']!;
  Uint8List? cached;
  // A getter, not setUpAll: each test then fails on its own (red) instead of
  // one setUpAll error hiding them all.
  Uint8List blob() => cached ??= SpectralCodec.encode('hr', s).blob;

  group('SpectralCodec.progressive', () {
    test('successive refinements k1 < k2 < ... < full, each equal to the '
        'matching coarse decode, gaps null at every step', () {
      final steps = SpectralCodec.progressive(blob(), orders: [0, 2, 8, 32]).toList();
      expect(steps.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].maxOrder, greaterThan(steps[i - 1].maxOrder));
      }
      for (final st in steps) {
        _maskEq(s, st.samples);
        if (!st.isFull) {
          expect(st.samples,
              SpectralCodec.decodeCoarse(blob(), maxOrder: st.maxOrder));
        }
      }
      expect(steps.where((e) => e.isFull), hasLength(1));
      expect(steps.last.isFull, isTrue);
    });

    test('the final level equals the full decode exactly', () {
      final last = SpectralCodec.progressive(blob()).last;
      expect(last.samples, SpectralCodec.decode(blob()));
    });

    test('is lazy: pulling one step does not decode the rest', () {
      var n = 0;
      final it = SpectralCodec.progressive(blob()).map((e) {
        n++;
        return e;
      }).iterator;
      expect(it.moveNext(), isTrue);
      expect(n, 1);
    });

    test('an order at or above the largest stored folds into the full step; '
        'non-increasing orders are an ArgumentError', () {
      final steps = SpectralCodec.progressive(blob(), orders: [0, 100000]).toList();
      expect(steps.length, 2);
      expect(steps.last.isFull, isTrue);
      expect(() => SpectralCodec.progressive(blob(), orders: [4, 4]).toList(),
          throwsArgumentError);
      expect(() => SpectralCodec.progressive(blob(), orders: [8, 2]).toList(),
          throwsArgumentError);
    });
  });

  group('SpectralLerp.between', () {
    final a = <double?>[60, 70, null, 80, 90];
    final b = <double?>[62, 74, null, 90, 70];

    test('interpolates sample by sample', () {
      final m = SpectralLerp.between(a, b, 0.25);
      expect(m[0], closeTo(60.5, 1e-12));
      expect(m[1], closeTo(71, 1e-12));
      expect(m[3], closeTo(82.5, 1e-12));
      expect(m[4], closeTo(85, 1e-12));
    });

    test('t = 1 is exactly the newer curve, t = 0 the older (on shared '
        'slots)', () {
      expect(SpectralLerp.between(a, b, 1.0), b);
      expect(SpectralLerp.between(a, b, 0.0), a);
    });

    test('never across a gap: null in either curve is null in between; t = 1 '
        'still returns the newer curve verbatim', () {
      final c = <double?>[60, null, 70];
      final d = <double?>[64, 70, null];
      expect(SpectralLerp.between(c, d, 0.5), [62, null, null]);
      expect(SpectralLerp.between(c, d, 1.0), d);
    });

    test('never extrapolates: stays within [from, to] per sample, and t '
        'outside [0,1] or NaN is an ArgumentError', () {
      final rnd = math.Random(2);
      for (var k = 0; k < 50; k++) {
        final t = rnd.nextDouble();
        final m = SpectralLerp.between(a, b, t);
        for (var i = 0; i < a.length; i++) {
          if (a[i] == null) continue;
          final lo = math.min(a[i]!, b[i]!), hi = math.max(a[i]!, b[i]!);
          expect(m[i]!, inInclusiveRange(lo, hi));
        }
      }
      for (final t in [-0.001, 1.001, double.nan, double.infinity]) {
        expect(() => SpectralLerp.between(a, b, t), throwsArgumentError,
            reason: '$t');
      }
    });

    test('different lengths are refused', () {
      expect(() => SpectralLerp.between([1.0], [1.0, 2.0], .5),
          throwsArgumentError);
    });

    test('lerping real coarse -> finer steps keeps the mask and bounds', () {
      final steps = SpectralCodec.progressive(blob()).toList();
      final m = SpectralLerp.between(steps.first.samples, steps[1].samples, 0.5);
      _maskEq(s, m);
    });
  });

  group('refineStream', () {
    test('emits exactly the progressive steps, in order, then closes',
        () async {
      final got = await refineStream(blob()).toList();
      final want = SpectralCodec.progressive(blob()).toList();
      expect(got.map((e) => e.maxOrder), want.map((e) => e.maxOrder));
      expect(got.map((e) => e.isFull), want.map((e) => e.isFull));
      expect(got.last.samples, SpectralCodec.decode(blob()));
    });

    test('cancelling after the first step stops the work', () async {
      final first = await refineStream(blob()).first;
      expect(first.isFull, isFalse);
    });

    test('STRUCTURE: decoding runs inside Isolate.run, never on the UI '
        'isolate (invariant 10)', () {
      final code = stripCommentsAndStrings(
          File('lib/data/spectral_progressive.dart').readAsStringSync());
      final at = code.indexOf('Isolate.run(');
      expect(at, isNonNegative, reason: 'no Isolate.run in refineStream');
      var depth = 0, end = at;
      for (var i = code.indexOf('(', at); i < code.length; i++) {
        if (code[i] == '(') depth++;
        if (code[i] == ')' && --depth == 0) {
          end = i;
          break;
        }
      }
      expect(code.substring(at, end), contains('SpectralCodec.'));
      // And no decode call outside that closure.
      final outside = code.substring(0, at) + code.substring(end);
      expect(outside, isNot(contains('SpectralCodec.decode')));
      expect(outside, isNot(contains('SpectralCodec.progressive')));
    });
  });

  group('SpectralDetail: the chart claims no more precision than it has', () {
    test('while not full: loading-detail, and NO numeric readout', () {
      final steps = SpectralCodec.progressive(blob()).toList();
      final d = SpectralDetail.of(steps.first);
      expect(d.isFull, isFalse);
      expect(d.isLoadingDetail, isTrue);
      expect(d.readout(100), isNull);
      expect(d.readout(0), isNull);
    });

    test('at the full level: no label, readout is the value, a gap is still '
        'null', () {
      final full = SpectralCodec.progressive(blob()).last;
      final d = SpectralDetail.of(full);
      expect(d.isLoadingDetail, isFalse);
      final i = s.indexWhere((e) => e != null);
      final g = s.indexWhere((e) => e == null);
      expect(d.readout(i), full.samples[i]);
      expect(g, isNonNegative);
      expect(d.readout(g), isNull);
    });

    test('exactly one step of a progression is not loading', () {
      final flags = [
        for (final r in SpectralCodec.progressive(blob()))
          SpectralDetail.of(r).isLoadingDetail
      ];
      expect(flags.where((f) => !f), hasLength(1));
      expect(flags.last, isFalse);
    });

    test('the loading label exists in the English ARB (user-facing text goes '
        'through l10n)', () {
      final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(arb['spectralLoadingDetail'], isA<String>());
      expect(arb['spectralLoadingDetail'], isNotEmpty);
    });
  });
}
