// Sample-gap policy for EcgTapCounter (phase 8L, review finding E).
//
// Contact and no-contact must be OBSERVED to count. A hole in the sample clock
// (a lost or late-dropped packet) is not evidence of either, so it can neither
// complete an engage, nor complete a release, nor decide a deadline.
//
//  * a pending engage candidate is dropped by a gap (contact starts over);
//  * a release timer restarts at the first sample after a gap;
//  * a gap that swallows a deadline abandons the gesture ('sample_gap'): the
//    count cannot be vouched for, so nothing runs;
//  * a gap inside a window that still has time left only costs the unseen time.
//
// "Gap" = consecutive samples further apart than maxSampleGap (default 50 ms).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(const Duration(seconds: 1)),
      hex: '',
      deviceId: 'band',
    );

Duration _ms(int v) => Duration(milliseconds: v);

class _Run {
  _Run(int max, {EcgTapThresholds? th})
      : c = EcgTapCounter(max: max, thresholds: th);
  final EcgTapCounter c;
  final List<EcgTapOutput> out = [];

  void begin(int open) {
    out.addAll(c.start(_tap(), at: Duration.zero));
    out.addAll(c.open(_ms(open)));
  }

  void at(int t, bool contact) => out.addAll(c.sample(_ms(t), contact: contact));
  void span(int from, int to, bool contact) {
    for (var t = from; t < to; t += 10) {
      at(t, contact);
    }
  }

  EcgTapDone? get done => out.whereType<EcgTapDone>().firstOrNull;
  EcgTapAbandoned? get abandoned =>
      out.whereType<EcgTapAbandoned>().firstOrNull;
  List<EcgTapBuzz> get buzzes => out.whereType<EcgTapBuzz>().toList();
}

void main() {
  test('the default tolerance is one sample period plus 40 ms', () {
    expect(EcgTapCounter(max: 3).maxSampleGap, _ms(50));
  });

  group('engage needs OBSERVED contact', () {
    test('contact either side of a 900 ms hole does not engage', () {
      final r = _Run(3, th: EcgTapThresholds(startMs: 1100))..begin(1000);
      r.span(1000, 1100, true); // 100 ms seen
      r.span(2000, 2100, true); // 900 ms unseen, then 100 ms more
      expect(r.done, isNull);
      expect(r.buzzes, isEmpty, reason: 'nothing counted, nothing decided');
      expect(r.c.count, 2);
    });

    test('a hole that carries a pending touch past its deadline abandons', () {
      // Window [1000, 1300). Candidate starts 1100, hole, contact at 1500.
      final r = _Run(3)..begin(1000);
      r.span(1000, 1100, false);
      r.span(1100, 1150, true);
      r.span(1500, 1700, true);
      expect(r.abandoned?.reason, 'sample_gap');
      expect(r.done, isNull);
    });

    test('a hole inside a window that is still open only drops the candidate',
        () {
      // Window [1000, 1600). Candidate 1020..1050, hole, contact again 1100:
      // a NEW candidate from 1100, engaged at 1300 (not at 1220).
      final r = _Run(3, th: EcgTapThresholds(startMs: 600))..begin(1000);
      r.span(1000, 1020, false);
      r.span(1020, 1050, true);
      r.span(1100, 1290, true);
      expect(r.done, isNull, reason: '1020 + 200 = 1220 would have engaged');
      r.at(1300, true);
      expect(r.c.count, 3);
      expect(r.done?.count, 3);
    });

    test('continuous samples 50 ms apart still count as continuous', () {
      final r = _Run(3)..begin(1000);
      for (var t = 1000; t <= 1250; t += 50) {
        r.at(t, true);
      }
      expect(r.done?.count, 3);
    });

    test('samples 60 ms apart are a gap', () {
      final r = _Run(3, th: EcgTapThresholds(startMs: 600))..begin(1000);
      for (var t = 1000; t <= 1240; t += 60) {
        r.at(t, true); // would engage at 1240 if bridged
      }
      expect(r.done, isNull);
      expect(r.c.count, 2);
    });
  });

  group('release needs OBSERVED no-contact', () {
    test('a hole after the contact does not complete the release', () {
      final r = _Run(5)..begin(1000);
      r.span(1000, 1210, true); // engage at 1200 -> count 3
      expect(r.c.count, 3);
      r.at(1210, false); // releasing starts
      r.at(1700, false); // 490 ms hole: the release timer restarts HERE
      // Bridged, the release would have completed at 1410 and the window
      // [1410, 1610) would already be past: a confirm at 1700.
      expect(r.done, isNull);
      expect(r.abandoned, isNull);
      r.span(1710, 1900, false); // 200 ms observed since 1700 at 1900
      expect(r.done, isNull);
      r.at(1900, false); // release complete -> window [1900, 2100)
      r.span(1910, 2100, false);
      r.at(2100, false);
      expect(r.done?.count, 3);
    });

    test('contact returning after a hole is the same touch (no new count)', () {
      final r = _Run(5)..begin(1000);
      r.span(1000, 1210, true); // count 3
      r.at(1210, false);
      r.span(1800, 2000, true); // hole, then contact
      expect(r.c.count, 3, reason: 'the unseen release is not a second touch');
      expect(r.done, isNull);
    });
  });

  group('a hole cannot decide a deadline', () {
    test('a hole spanning the first window abandons instead of confirming 2',
        () {
      final r = _Run(5)..begin(1000); // window [1000, 1300)
      r.span(1000, 1100, false);
      r.at(1900, false); // 800 ms hole carrying us past the deadline
      expect(r.abandoned?.reason, 'sample_gap');
      expect(r.done, isNull);
      expect(r.buzzes, isEmpty, reason: 'no count buzz, no confirmation');
      expect(r.c.finished, isTrue);
    });

    test('a hole spanning the post-release window abandons too', () {
      final r = _Run(5)..begin(1000);
      r.span(1000, 1210, true); // count 3
      r.span(1210, 1420, false); // release complete at 1410 -> [1410, 1610)
      r.at(2400, false); // hole across the deadline
      expect(r.abandoned?.reason, 'sample_gap');
      expect(r.done, isNull);
    });

    test('a hole shorter than the remaining window changes nothing', () {
      final r = _Run(5, th: EcgTapThresholds(startMs: 600))..begin(1000);
      r.span(1000, 1100, false);
      r.span(1300, 1700, false); // hole 1100..1300, deadline at 1600
      expect(r.done?.count, 2, reason: 'confirmed by a sample at/after 1600');
      expect(r.abandoned, isNull);
    });

    test('the first sample after the window opens is checked like any other',
        () {
      final r = _Run(5)..begin(1000); // boundary 1000, deadline 1300
      r.at(2000, true); // nothing observed between 1000 and 2000
      expect(r.abandoned?.reason, 'sample_gap');
    });
  });

  group('the tolerance is configurable', () {
    test('a wider maxSampleGap bridges what the default would not', () {
      final c = EcgTapCounter(max: 3, maxSampleGap: _ms(300));
      c.start(_tap(), at: Duration.zero);
      c.open(_ms(1000));
      final out = <EcgTapOutput>[];
      for (var t = 1000; t <= 1250; t += 125) {
        out.addAll(c.sample(_ms(t), contact: true));
      }
      expect(out.whereType<EcgTapDone>().firstOrNull?.count, 3);
    });
  });
}
