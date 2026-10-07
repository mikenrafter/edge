// The StillnessMeter on its own: per-second SD of the acceleration magnitude
// against a proposed gate, unknown seconds that are never counted as still,
// and per-second summaries only (RAM bounded).
//
// Samples are in g. A scene is built from a magnitude function over the
// sample index, put on the x axis; with `a +- b` alternating, the population
// SD of the magnitude is exactly b.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/resonance/stillness_meter.dart';

Duration ms(int n) => Duration(milliseconds: n);
Duration sec(int n) => Duration(seconds: n);

/// Whole-number-of-seconds scene: [hz] samples a second from [from] to [to]
/// (seconds), starting [offsetMs] into the first second, magnitude from
/// [mag] (g) by the sample index within the second.
void feed(
  StillnessMeter m,
  int from,
  int to, {
  int hz = 100,
  int offsetMs = 0,
  double Function(int s, int k)? mag,
}) {
  for (var s = from; s < to; s++) {
    for (var k = 0; k < hz; k++) {
      final t = ms(s * 1000 + offsetMs + (k * 1000) ~/ hz);
      final g = mag?.call(s, k) ?? 1.0;
      m.add(t, g, 0, 0);
    }
  }
}

/// 1 g with an alternating +-[sd] ripple: SD of the magnitude is [sd].
double Function(int, int) rippled(double sd) =>
    (s, k) => 1.0 + (k.isEven ? sd : -sd);

void main() {
  group('the proposed gates', () {
    test('are named and documented as engineering gates', () {
      expect(kStillSdG, 0.02);
      expect(kMinSamplesPerSecond, 50);
      expect(kMinKnownShare, 0.8);
      final source =
          File('lib/explore/resonance/stillness_meter.dart').readAsStringSync();
      expect(source, contains('Proposed engineering gate'));
    });
  });

  group('a second is still when the SD of the magnitude is below the gate',
      () {
    test('a constant reading is still', () {
      final m = StillnessMeter();
      feed(m, 0, 120);
      expect(m.stillFraction(sec(0), sec(120)), 1.0);
    });

    test('just under the gate is still; just over it is not', () {
      final under = StillnessMeter();
      feed(under, 0, 60, mag: rippled(kStillSdG * 0.95));
      expect(under.stillFraction(sec(0), sec(60)), 1.0);

      final over = StillnessMeter();
      feed(over, 0, 60, mag: rippled(kStillSdG * 1.05));
      expect(over.stillFraction(sec(0), sec(60)), 0.0);
    });

    test('magnitude, not axes: gravity turning between axes is still', () {
      final m = StillnessMeter();
      for (var i = 0; i < 100 * 60; i++) {
        final angle = i * 0.002; // a slow tilt of the wrist
        m.add(ms(i * 10), math.cos(angle), math.sin(angle), 0);
      }
      expect(m.stillFraction(sec(0), sec(60)), 1.0);
    });

    test('one spike makes its second not still (not averaged away)', () {
      final m = StillnessMeter();
      feed(m, 0, 10, mag: (s, k) => s == 4 && k == 50 ? 2.0 : 1.0);
      expect(m.stillFraction(sec(0), sec(10)), closeTo(0.9, 1e-9));
    });

    test('the fraction is still seconds over known seconds', () {
      final m = StillnessMeter();
      feed(m, 0, 90);
      feed(m, 90, 120, mag: rippled(0.5));
      expect(m.stillFraction(sec(0), sec(120)), closeTo(0.75, 1e-9));
    });
  });

  group('seconds with too few samples are unknown, never still', () {
    test('49 samples is unknown, 50 is known', () {
      final m49 = StillnessMeter();
      feed(m49, 0, 10, hz: kMinSamplesPerSecond - 1);
      expect(m49.stillFraction(sec(0), sec(10)), isNull,
          reason: 'no second reaches the minimum, so nothing is known');
      final m50 = StillnessMeter();
      feed(m50, 0, 10, hz: kMinSamplesPerSecond);
      expect(m50.stillFraction(sec(0), sec(10)), 1.0);
    });

    test('unknown seconds leave both sides of the ratio', () {
      // 10 s span: 2 unknown (thin), 4 still, 4 shaken => 4 / 8, not 4 / 10
      // (unknown counted as moving) and not 8 / 10 (counted as still).
      final m = StillnessMeter();
      feed(m, 0, 4);
      feed(m, 4, 8, mag: rippled(0.5));
      feed(m, 8, 10, hz: 10);
      expect(m.stillFraction(sec(0), sec(10)), closeTo(0.5, 1e-9));
    });

    test('known below 80% of the span: null; at exactly 80%: an answer', () {
      final seven = StillnessMeter();
      feed(seven, 0, 7);
      feed(seven, 7, 10, hz: 10);
      expect(seven.stillFraction(sec(0), sec(10)), isNull,
          reason: '7 of 10 seconds known');

      final eight = StillnessMeter();
      feed(eight, 0, 8);
      feed(eight, 8, 10, hz: 10);
      expect(eight.stillFraction(sec(0), sec(10)), 1.0,
          reason: '8 of 10 seconds known is not below 80%');
    });

    test('no samples at all, or samples only outside the span: null', () {
      final empty = StillnessMeter();
      expect(empty.stillFraction(sec(0), sec(60)), isNull);

      final elsewhere = StillnessMeter();
      feed(elsewhere, 100, 160);
      expect(elsewhere.stillFraction(sec(0), sec(60)), isNull);
    });

    test('a span with no whole second (empty or reversed): null', () {
      final m = StillnessMeter();
      feed(m, 0, 60);
      expect(m.stillFraction(sec(10), sec(10)), isNull);
      expect(m.stillFraction(sec(20), sec(10)), isNull);
      expect(m.stillFraction(ms(10100), ms(10900)), isNull);
    });

    test('samples that are not finite do not count, and do not poison', () {
      final m = StillnessMeter();
      feed(m, 0, 5);
      for (var s = 0; s < 5; s++) {
        for (var k = 0; k < 30; k++) {
          m.add(ms(s * 1000 + k), double.nan, 0, 0);
          m.add(ms(s * 1000 + k), 1, double.infinity, 0);
        }
      }
      expect(m.stillFraction(sec(0), sec(5)), 1.0);

      final thin = StillnessMeter();
      feed(thin, 0, 5, hz: 40);
      for (var s = 0; s < 5; s++) {
        for (var k = 0; k < 60; k++) {
          thin.add(ms(s * 1000 + k), double.nan, 0, 0);
        }
      }
      expect(thin.stillFraction(sec(0), sec(5)), isNull,
          reason: '40 finite samples a second is below the minimum');
    });
  });

  group('windows and ordering', () {
    test('a window is whole seconds, [from, to): the edges belong to '
        'their own second', () {
      // Only second 29 and second 150 are shaken.
      final clean = StillnessMeter();
      feed(clean, 0, 29);
      feed(clean, 29, 30, mag: rippled(0.5));
      feed(clean, 30, 150);
      feed(clean, 150, 151, mag: rippled(0.5));
      feed(clean, 151, 200);
      expect(clean.stillFraction(sec(30), sec(150)), 1.0,
          reason: 'second 29 and second 150 lie outside [30, 150)');
      expect(clean.stillFraction(sec(29), sec(150)), closeTo(119 / 120, 1e-9));
      expect(clean.stillFraction(sec(30), sec(151)), closeTo(120 / 121, 1e-9));
    });

    test('a packet that straddles a second boundary still fills both seconds',
        () {
      final m = StillnessMeter();
      feed(m, 0, 60, offsetMs: 505);
      // 505 ms offset: second 0 holds samples 505..995 and the next
      // second's tail, but every second ends up with its full 100 samples
      // from the stream. Seconds 1..58 are complete.
      expect(m.stillFraction(sec(1), sec(58)), 1.0);
    });

    test('order does not matter, and negative times are ignored', () {
      final forward = StillnessMeter();
      final backward = StillnessMeter();
      final samples = <(int, double)>[
        for (var i = 0; i < 100 * 20; i++)
          (i * 10, i % 7 == 0 && i < 300 ? 1.4 : 1.0),
      ];
      for (final (t, g) in samples) {
        forward.add(ms(t), g, 0, 0);
      }
      for (final (t, g) in samples.reversed) {
        backward.add(ms(t), g, 0, 0);
      }
      backward.add(const Duration(milliseconds: -500), 9, 9, 9);
      expect(backward.stillFraction(sec(0), sec(20)),
          forward.stillFraction(sec(0), sec(20)));
      expect(forward.stillFraction(sec(0), sec(20)), closeTo(17 / 20, 1e-9));
    });

    test('asking twice gives the same answer', () {
      final m = StillnessMeter();
      feed(m, 0, 30);
      feed(m, 30, 40, mag: rippled(0.5));
      final first = m.stillFraction(sec(0), sec(40));
      expect(m.stillFraction(sec(0), sec(40)), first);
    });
  });

  group('RAM: only per-second summaries, and not an unbounded number', () {
    test('a minute at 100 Hz is 60 summaries, not 6000 samples', () {
      final m = StillnessMeter();
      feed(m, 0, 60);
      expect(m.summaryCount, 60);
    });

    test('the oldest seconds are dropped past the cap and read as unknown',
        () {
      final m = StillnessMeter(maxSeconds: 120);
      feed(m, 0, 600, hz: 50);
      expect(m.summaryCount, lessThanOrEqualTo(120));
      expect(m.stillFraction(sec(0), sec(100)), isNull,
          reason: 'long since dropped: unknown, not still');
      expect(m.stillFraction(sec(500), sec(600)), 1.0);
    });

    test('a sample for a second that was already dropped is ignored', () {
      final m = StillnessMeter(maxSeconds: 10);
      feed(m, 100, 200, hz: 50);
      final before = m.summaryCount;
      m.add(ms(1000), 1, 0, 0);
      expect(m.summaryCount, before);
    });
  });

  group('it is pure', () {
    test('imports only dart core libraries and keeps no sample list', () {
      final source =
          File('lib/explore/resonance/stillness_meter.dart').readAsStringSync();
      final imports = RegExp(r"^import '([^']+)';", multiLine: true)
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toList();
      expect(imports.where((i) => !i.startsWith('dart:math')), isEmpty,
          reason: 'no db, no file, no flutter: a prototype-pure meter');
    });
  });
}
