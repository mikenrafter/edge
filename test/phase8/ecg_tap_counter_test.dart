// 8L — EcgTapCounter: draft 3–5 tap gestures counted as touches on the WHOOP MG
// ECG sensor after a live firmware double tap. Pure state machine; every time
// is ECG SAMPLE time (a Duration on the stream's clock), never phone receipt
// time. Deadlines are decided by samples; clock ticks only detect a stalled
// stream. See test/phase8/CONTRACTS.md §8L.
//
// Timeline vocabulary used below (ms on the sample clock), default thresholds
// (start 300, gap 200, confirm 200):
//   start(tap) at 0 -> nothing buzzes yet; open(500) -> first window
//   [500, 500+start). A touch that engages there is tap 3 and buzzes three
//   times; no touch by the deadline buzzes twice and ends at 2. Later taps buzz
//   once, and a window running out after tap 3 confirms with one more buzz.
//   Engage = `gap` ms continuous contact. Release = `gap` ms
//   continuous no-contact. After contact ends at E, a next touch must START in
//   [E+gap, E+gap+confirm); at E+gap+confirm with no new touch it confirms.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap({Duration late = const Duration(seconds: 1)}) => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(late),
      hex: '',
      deviceId: 'band',
    );

Duration _ms(int v) => Duration(milliseconds: v);

/// A test driver: feeds samples every 10 ms (plus any exact edge samples) and
/// keeps every output in order.
class _Run {
  _Run(int max, {EcgTapThresholds? th})
      : c = th == null
            ? EcgTapCounter(max: max)
            : EcgTapCounter(max: max, thresholds: th);
  final EcgTapCounter c;
  final List<EcgTapOutput> out = [];

  void start() => out.addAll(c.start(_tap(), at: Duration.zero));
  void open(int at) => out.addAll(c.open(_ms(at)));
  void at(int t, bool contact) => out.addAll(c.sample(_ms(t), contact: contact));

  /// Samples every 10 ms in [from, to), all with the same contact state.
  void span(int from, int to, bool contact) {
    for (var t = from; t < to; t += 10) {
      at(t, contact);
    }
  }

  List<EcgTapBuzz> get buzzes => out.whereType<EcgTapBuzz>().toList();
  EcgTapDone? get done => out.whereType<EcgTapDone>().firstOrNull;
  bool get abandoned => out.any((o) => o is EcgTapAbandoned);
}

/// start + window open at 500.
_Run _begin(int max, {EcgTapThresholds? th}) {
  final r = _Run(max, th: th)..start();
  expect(r.buzzes, isEmpty, reason: 'nothing buzzes until the first window');
  r.open(500);
  return r;
}

/// Count 3: contact 600..1190 (engage at 800), contact ends at 1200.
_Run _toThree(int max) {
  final r = _begin(max);
  r.span(500, 600, false);
  r.span(600, 1200, true);
  return r;
}

void main() {
  group('construction and start', () {
    test('max must be 2..5', () {
      for (final bad in [0, 1, 6]) {
        expect(() => EcgTapCounter(max: bad), throwsArgumentError);
      }
      for (final ok in [2, 3, 4, 5]) {
        expect(EcgTapCounter(max: ok).max, ok);
      }
    });

    test('default thresholds and stall timeout', () {
      final c = EcgTapCounter(max: 5);
      expect(c.thresholds, EcgTapThresholds());
      expect(c.thresholds.startMs, 300);
      expect(c.thresholds.gapMs, 200);
      expect(c.thresholds.confirmMs, 200);
      expect(c.stallAfter, _ms(500));
    });

    test('a live double tap starts at count 2 and buzzes nothing yet', () {
      final c = EcgTapCounter(max: 5);
      final out = c.start(_tap(), at: Duration.zero);
      expect(c.started, isTrue);
      expect(c.count, 2);
      expect(out, isEmpty);
    });

    test('a late (non-live) double tap never starts the counter', () {
      final c = EcgTapCounter(max: 5);
      expect(c.start(_tap(late: const Duration(hours: 2)), at: Duration.zero),
          isEmpty);
      expect(c.started, isFalse);
      expect(c.open(_ms(500)), isEmpty);
      expect(c.sample(_ms(600), contact: true), isEmpty);
      expect(c.sample(_ms(900), contact: true), isEmpty);
    });

    test('samples before the window opens are ignored', () {
      final r = _Run(5)..start();
      r.span(0, 400, true); // finger still on the band from the tap
      r.open(500);
      r.span(500, 800, false);
      r.at(800, false);
      expect(r.done?.count, 2);
    });
  });

  group('the examples (max = 5)', () {
    test('2: taptap · no touch for 300 ms · buzz buzz, ends', () {
      final r = _begin(5);
      r.span(500, 800, false);
      expect(r.done, isNull, reason: 'window still open at 790');
      expect(r.buzzes, isEmpty);
      r.at(800, false);
      expect(r.done!.count, 2);
      expect(r.done!.at, _ms(800));
      expect(r.buzzes.map((b) => b.pulses), [2],
          reason: 'the count buzz is the confirmation: no extra buzz');
      expect(r.buzzes.last.at, _ms(800));
    });

    test('3: touch < 300 ms · buzz buzz buzz · release · > 400 ms · buzz',
        () {
      final r = _toThree(5);
      expect(r.buzzes.map((b) => b.pulses), [3]);
      expect(r.buzzes[0].at, _ms(800), reason: 'engage = start + 200 ms');
      expect(r.c.count, 3);
      r.span(1200, 1600, false);
      expect(r.done, isNull);
      r.at(1600, false);
      expect(r.done!.count, 3);
      expect(r.buzzes.map((b) => b.pulses), [3, 1]);
    });

    test('3: a finger already on the sensor when the window opens', () {
      final r = _Run(5)..start();
      r.span(0, 500, true); // resting on the sensor before it was ready
      r.open(500);
      r.span(500, 700, true);
      r.at(700, true);
      expect(r.c.count, 3);
      expect(r.buzzes.single.pulses, 3);
      expect(r.buzzes.single.at, _ms(700),
          reason: 'held from the window opening: open + gap');
    });

    test('4: … release · touch 200–400 ms · buzz · release · > 400 ms · buzz',
        () {
      final r = _toThree(5);
      r.span(1200, 1500, false);
      r.span(1500, 2000, true); // starts 300 ms after contact ended
      expect(r.c.count, 4);
      expect(r.buzzes.last.at, _ms(1700));
      r.span(2000, 2400, false);
      r.at(2400, false);
      expect(r.done!.count, 4);
      expect(r.buzzes.map((b) => b.pulses), [3, 1, 1]);
    });

    test('5: … touch 200–400 ms · buzz (max, runs at once)', () {
      final r = _toThree(5);
      r.span(1200, 1500, false);
      r.span(1500, 2000, true); // count 4
      r.span(2000, 2300, false);
      r.span(2300, 2500, true);
      r.at(2500, true); // engage at 2500 -> count 5 = max
      expect(r.done!.count, 5);
      expect(r.done!.at, _ms(2500));
      expect(r.buzzes.map((b) => b.pulses), [3, 1, 1],
          reason: 'the max buzz is the last one; no confirm buzz after it');
      r.span(2510, 4000, false);
      expect(r.out.whereType<EcgTapDone>(), hasLength(1));
    });
  });

  group('max', () {
    test('max = 2: done at start, no wait, no window', () {
      final c = EcgTapCounter(max: 2);
      final out = c.start(_tap(), at: Duration.zero);
      expect(out.whereType<EcgTapDone>().single.count, 2);
      expect(c.finished, isTrue);
      expect(c.open(_ms(500)), isEmpty);
    });

    test('max = 3: the third touch runs at once', () {
      final r = _begin(3);
      r.span(500, 600, false);
      r.span(600, 800, true);
      r.at(800, true);
      expect(r.done!.count, 3);
      expect(r.done!.at, _ms(800));
      expect(r.buzzes.map((b) => b.pulses), [3],
          reason: 'the three-pulse count buzz is the confirmation');
    });

    test('max = 4: the fourth touch runs at once', () {
      final r = _toThree(4);
      r.span(1200, 1500, false);
      r.span(1500, 1700, true);
      r.at(1700, true);
      expect(r.done!.count, 4);
      expect(r.done!.at, _ms(1700));
    });

    test('max = 5 never stops early', () {
      final r = _toThree(5);
      r.span(1200, 1500, false);
      r.span(1500, 1710, true);
      expect(r.c.count, 4);
      expect(r.done, isNull);
    });
  });

  group('contact debouncing', () {
    test('a contact blip < 200 ms in the window does not engage', () {
      final r = _begin(5);
      r.span(500, 600, false);
      r.span(600, 750, true); // 150 ms
      r.span(750, 800, false);
      r.at(800, false);
      expect(r.done!.count, 2);
    });

    test('a no-contact blip < 200 ms during a touch does not release', () {
      final r = _begin(5);
      r.span(500, 600, false);
      r.span(600, 900, true); // engaged at 800 -> 3
      r.span(900, 1050, false); // 150 ms gap: same touch
      r.span(1050, 1200, true);
      r.span(1200, 1600, false);
      r.at(1600, false);
      expect(r.done!.count, 3, reason: 'the gap was not a second touch');
      expect(r.buzzes.map((b) => b.pulses), [3, 1]);
    });

    test('a touch that starts at the end of the first window is too late', () {
      final r = _begin(5);
      r.span(500, 800, false);
      r.at(800, true);
      r.span(810, 1100, true);
      expect(r.done!.count, 2);
      expect(r.done!.at, _ms(800));
    });
  });

  group('re-engage after contact ended at 1200', () {
    test('199 ms: the same touch (no count)', () {
      final r = _toThree(5);
      r.span(1200, 1399, false);
      r.at(1399, true);
      r.span(1400, 1500, true);
      r.span(1500, 1900, false);
      r.at(1900, false);
      expect(r.done!.count, 3);
    });

    test('201 ms: a new touch, counted at engage', () {
      final r = _toThree(5);
      r.span(1200, 1410, false); // includes the 1400 sample: released
      r.at(1401, true);
      r.span(1410, 1610, true);
      r.at(1610, true);
      expect(r.c.count, 4);
      expect(r.buzzes.last.at, greaterThanOrEqualTo(_ms(1601)));
      expect(r.buzzes.last.at, lessThanOrEqualTo(_ms(1610)));
    });

    test('401 ms: too late, the gesture already confirmed at 400 ms', () {
      final r = _toThree(5);
      r.span(1200, 1600, false);
      r.at(1600, false);
      expect(r.done!.count, 3);
      expect(r.done!.at, _ms(1600));
      r.at(1601, true);
      r.span(1610, 2000, true);
      expect(r.out.whereType<EcgTapDone>(), hasLength(1));
      expect(r.c.count, 3);
    });
  });

  group('abandon: no action', () {
    test('a link drop mid-gesture abandons, and nothing runs after it', () {
      final r = _toThree(5);
      r.out.addAll(r.c.linkLost(_ms(1300)));
      expect(r.abandoned, isTrue);
      r.span(1300, 3000, false);
      expect(r.done, isNull);
      expect(r.c.finished, isTrue);
    });

    test('a stalled stream (ticks, no samples) abandons', () {
      final r = _begin(5);
      r.span(500, 600, false);
      r.at(600, false); // last sample at 600
      r.out.addAll(r.c.tick(_ms(600) + r.c.stallAfter - _ms(1)));
      expect(r.abandoned, isFalse);
      r.out.addAll(r.c.tick(_ms(600) + r.c.stallAfter));
      expect(r.abandoned, isTrue);
      expect(r.done, isNull, reason: 'a deadline is never decided by a tick');
    });

    test('ticks alone never confirm a count', () {
      final r = _begin(5);
      r.span(500, 790, false);
      r.out.addAll(r.c.tick(_ms(800)));
      expect(r.done, isNull);
    });
  });
  group('EcgTapThresholds: range and step', () {
    test('ranges and step are named constants', () {
      expect(EcgTapThresholds.stepMs, 50);
      expect(EcgTapThresholds.startRange, (200, 1100));
      expect(EcgTapThresholds.gapRange, (100, 1000));
      expect(EcgTapThresholds.confirmRange, (100, 1000));
    });

    test('accepts every edge of every range', () {
      for (final (s, g, c) in [(200, 100, 100), (1100, 1000, 1000)]) {
        final th = EcgTapThresholds(startMs: s, gapMs: g, confirmMs: c);
        expect((th.startMs, th.gapMs, th.confirmMs), (s, g, c));
        expect(th.start, _ms(s));
        expect(th.gap, _ms(g));
        expect(th.confirm, _ms(c));
      }
    });

    for (final (name, make) in <(String, EcgTapThresholds Function())>[
      ('start below range', () => EcgTapThresholds(startMs: 150)),
      ('start above range', () => EcgTapThresholds(startMs: 1150)),
      ('start off step', () => EcgTapThresholds(startMs: 325)),
      ('gap below range', () => EcgTapThresholds(gapMs: 50)),
      ('gap above range', () => EcgTapThresholds(gapMs: 1050)),
      ('gap off step', () => EcgTapThresholds(gapMs: 210)),
      ('confirm below range', () => EcgTapThresholds(confirmMs: 50)),
      ('confirm above range', () => EcgTapThresholds(confirmMs: 1050)),
      ('confirm off step', () => EcgTapThresholds(confirmMs: 199)),
    ]) {
      test('rejects $name (ArgumentError, never clamped)', () {
        expect(make, throwsArgumentError);
      });
    }

    test('value equality and copyWith', () {
      expect(EcgTapThresholds(startMs: 500), EcgTapThresholds(startMs: 500));
      expect(EcgTapThresholds().copyWith(gapMs: 300).gapMs, 300);
      expect(EcgTapThresholds().copyWith(gapMs: 300).startMs, 300);
      expect(() => EcgTapThresholds().copyWith(confirmMs: 5),
          throwsArgumentError);
    });

    test('extra sensitive: off by default, part of the value, in the summary',
        () {
      expect(EcgTapThresholds().extraSensitive, isFalse);
      final on = EcgTapThresholds().copyWith(extraSensitive: true);
      expect(on.extraSensitive, isTrue);
      expect(on, isNot(EcgTapThresholds()));
      expect(on.copyWith(gapMs: 300).extraSensitive, isTrue);
      expect(EcgTapThresholds().summary, isNot(contains('extra sensitive')));
      expect(on.summary, endsWith(', extra sensitive'));
    });
  });

  group('a changed threshold moves its boundary', () {
    test('start 500: a touch 450 ms after the window opens counts (default '
        'rejects it)',
        () {
      final moved = _begin(5, th: EcgTapThresholds(startMs: 500));
      moved.span(500, 950, false);
      moved.span(950, 1160, true); // engages at 1150
      expect(moved.c.count, 3);
      expect(moved.done, isNull);

      final dflt = _begin(5);
      dflt.span(500, 950, false);
      dflt.span(950, 1160, true);
      expect(dflt.done!.count, 2, reason: 'default window closed at 800');
    });

    test('start 500: with no touch, confirms at open + 500', () {
      final r = _begin(5, th: EcgTapThresholds(startMs: 500));
      r.span(500, 1000, false);
      expect(r.done, isNull);
      r.at(1000, false);
      expect(r.done!.count, 2);
      expect(r.done!.at, _ms(1000));
    });

    test('gap 300: 250 ms of contact no longer engages', () {
      final r = _begin(5, th: EcgTapThresholds(gapMs: 300));
      r.span(500, 600, false);
      r.span(600, 850, true); // 250 ms
      r.span(850, 1000, false);
      r.at(1000, false);
      expect(r.done!.count, 2);
    });

    test('gap 300: engage at start + 300', () {
      final r = _begin(5, th: EcgTapThresholds(gapMs: 300));
      r.span(500, 600, false);
      r.span(600, 910, true);
      expect(r.c.count, 3);
      expect(r.buzzes.last.at, _ms(900));
    });

    test('gap 300: a 250 ms no-contact gap is still the same touch', () {
      final r = _begin(5, th: EcgTapThresholds(gapMs: 300));
      r.span(500, 600, false);
      r.span(600, 1000, true); // engaged at 900 -> 3
      r.span(1000, 1250, false); // 250 ms < gap
      r.span(1250, 1400, true); // same touch, no count
      expect(r.c.count, 3);
      // Ends at 1400; next window [1700, 1900); confirm at 1900.
      r.span(1400, 1900, false);
      r.at(1900, false);
      expect(r.done!.count, 3);
      expect(r.done!.at, _ms(1900));
    });

    test('confirm 400: a next touch 500 ms after contact ended counts', () {
      final r = _toThree(5); // contact ended at 1200 (default gap 200)
      // ...but with confirm 400 the window is [1400, 1800).
      final moved = _Run(5, th: EcgTapThresholds(confirmMs: 400))..start();
      moved.open(500);
      moved.span(500, 600, false);
      moved.span(600, 1200, true);
      moved.span(1200, 1700, false);
      moved.span(1700, 1910, true); // starts 500 ms after the end
      expect(moved.c.count, 4);

      r.span(1200, 1700, false);
      expect(r.done!.count, 3, reason: 'default confirmed at 1600');
    });
  });
}
