// The touch counter asks for ONE follow-up cue per count
// increment, and one confirm cue when the gesture ends.
//
// The opening of a gesture is the double tap that starts it: count 2 (start()
// sets it). The start cue plays at the tap, before the counter exists, so the
// counter never asks for it. Every touch that engages after that is one
// increment: reaching 3, 4, 5 each asks for exactly one EcgTapBuzz (a
// follow-up), never a recount of the pulses so far. When the gesture ends
// counted (a window runs out, the max is reached, or max 2 ends at once) it
// asks for one EcgTapConfirm, before the EcgTapDone. An abandoned gesture asks
// for neither.
//
// ASSUMED API (lib/gestures/ecg_tap_counter.dart):
//   EcgTapBuzz(at)      one follow-up cue (no pulses field)
//   EcgTapConfirm(at)   the gesture ended counted: the confirm cue

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'support/legacy_ecg_thresholds.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 3, 8);

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(const Duration(seconds: 1)),
      hex: '',
      deviceId: 'band',
    );

Duration _ms(int v) => Duration(milliseconds: v);

/// The outputs in order, as short names.
class _Run {
  _Run(int max) : c = EcgTapCounter(max: max, thresholds: LegacyEcgThresholds());
  final EcgTapCounter c;
  final List<EcgTapOutput> out = [];

  void start() => out.addAll(c.start(_tap(), at: Duration.zero));
  void open(int at) => out.addAll(c.open(_ms(at)));
  void at(int t, bool contact) => out.addAll(c.sample(_ms(t), contact: contact));
  void span(int from, int to, bool contact) {
    for (var t = from; t < to; t += 10) {
      at(t, contact);
    }
  }

  List<String> get names => [
        for (final o in out)
          switch (o) {
            EcgTapBuzz() => 'follow',
            EcgTapConfirm() => 'confirm',
            EcgTapDone(:final count) => 'done$count',
            EcgTapAbandoned() => 'abandoned',
          },
      ];

  /// Touches 3, 4 and 5 with a release between (same timeline as the draft-taps tests).
  void toThree() {
    start();
    open(500);
    span(500, 600, false);
    span(600, 1200, true); // engage at 800: count 3
  }

  void toFour() {
    span(1200, 1500, false);
    span(1500, 2000, true); // engage at 1700: count 4
  }

  void toFive() {
    span(2000, 2300, false);
    span(2300, 2500, true);
    at(2500, true); // engage at 2500: count 5
  }
}

void main() {
  test('the opening is count 2: the double tap that starts the gesture', () {
    final c = EcgTapCounter(max: 5, thresholds: LegacyEcgThresholds());
    c.start(_tap(), at: Duration.zero);
    expect(c.count, 2);
  });

  group('one follow-up per increment', () {
    test('reaching 3 is one follow-up, nothing else', () {
      final r = _Run(5)..toThree();
      expect(r.c.count, 3);
      expect(r.names, ['follow']);
      expect((r.out.single as EcgTapBuzz).at, _ms(800));
    });

    test('reaching 4 is one more follow-up, not a recount', () {
      final r = _Run(5)
        ..toThree()
        ..toFour();
      expect(r.c.count, 4);
      expect(r.names, ['follow', 'follow']);
      expect((r.out.last as EcgTapBuzz).at, _ms(1700),
          reason: 'queued the moment the touch engages');
    });

    test('a gesture that goes to 5 is follow, follow, follow, then confirm, '
        'then done', () {
      final r = _Run(5)
        ..toThree()
        ..toFour()
        ..toFive();
      expect(r.names, ['follow', 'follow', 'follow', 'confirm', 'done5']);
      expect((r.out[2] as EcgTapBuzz).at, _ms(2500));
      expect((r.out[3] as EcgTapConfirm).at, _ms(2500));
    });
  });

  group('the confirm cue closes a counted gesture', () {
    test('ending at 2 (no touch): the confirm only', () {
      final r = _Run(5)
        ..start()
        ..open(500);
      r.span(500, 800, false);
      r.at(800, false);
      expect(r.names, ['confirm', 'done2']);
    });

    test('ending at 3: one follow-up, then the confirm', () {
      final r = _Run(5)..toThree();
      r.span(1200, 1600, false);
      r.at(1600, false);
      expect(r.names, ['follow', 'confirm', 'done3']);
    });

    test('ending at 4: follow, follow, confirm', () {
      final r = _Run(5)
        ..toThree()
        ..toFour();
      r.span(2000, 2400, false);
      r.at(2400, false);
      expect(r.names, ['follow', 'follow', 'confirm', 'done4']);
    });

    test('max 3 reached: the follow-up for 3, then the confirm', () {
      final r = _Run(3)
        ..start()
        ..open(500);
      r.span(500, 600, false);
      r.span(600, 800, true);
      r.at(800, true);
      expect(r.names, ['follow', 'confirm', 'done3']);
    });

    test('max 2: the confirm only, at once', () {
      final r = _Run(2)..start();
      expect(r.names, ['confirm', 'done2']);
    });

    test('no finger on the quick start: the confirm only', () {
      final r = _Run(5)..start();
      r.out.addAll(r.c.noFinger(_ms(400)));
      expect(r.names, ['confirm', 'done2']);
    });

    test('an abandoned gesture asks for neither follow-up nor confirm', () {
      final r = _Run(5)
        ..toThree();
      r.out.addAll(r.c.linkLost(_ms(1300)));
      expect(r.names, ['follow', 'abandoned']);
    });
  });
}
