// EcgPresenceGate (8AN C, hybrid): the fast path keeps the sample-timed
// EcgTapCounter and its ms thresholds on the 10 ms ecgContactMask; the band's
// debounced presence bit is only a per-packet VETO. Sample contact inside a
// packet whose presence bit is false is treated as no contact for that packet's
// samples (this filters the noisy early packets the sensor settle used to
// protect against); packets with presence true use the sample mask as-is.
// If the band never sets presence while samples show contact for
// kEcgPresenceFallbackPackets consecutive packets, the veto is lifted for the
// rest of the gesture.
//
// ASSUMED API (new; lib/gestures/ecg_presence_gate.dart, pure, no Flutter):
//   const int kEcgPresenceFallbackPackets = 4;
//   class EcgPresenceGate {
//     EcgPresenceGate({int fallbackPackets = kEcgPresenceFallbackPackets});
//     final int fallbackPackets;
//     bool get everPresent;   // a packet with presence true was seen
//     bool get fellBack;      // the veto is lifted (sticky for the gesture)
//     int get suspectRun;     // consecutive presence-false packets with sample
//                             // contact, counted only while !everPresent && !fellBack
//     bool get holdsFirstWindow; // !fellBack && !everPresent && suspectRun > 0:
//                                // the session must not let the first touch
//                                // window close on these packets
//     List<bool> filter(List<bool> mask, {required bool presence});
//         // The mask the counter should see for ONE packet; advances state.
//         // presence true: mask unchanged, everPresent = true, run reset.
//         // presence false, veto in force: all false (same length).
//         // The packet that completes the run of [fallbackPackets] sets fellBack
//         // and is itself returned UNMASKED; so is every packet after it,
//         // whatever its presence bit says.
//         // A presence-false packet with no sample contact resets the run.
//   }

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_presence_gate.dart';

List<bool> _contact([int n = 100, int from = 0, int to = 100]) =>
    [for (var i = 0; i < n; i++) i >= from && i < to];
List<bool> _none([int n = 100]) => List<bool>.filled(n, false);

void main() {
  test('the default fallback run is four packets', () {
    expect(kEcgPresenceFallbackPackets, 4);
    expect(EcgPresenceGate().fallbackPackets, 4);
  });

  group('the veto', () {
    test('presence true: the sample mask passes through unchanged', () {
      final g = EcgPresenceGate();
      final m = _contact(100, 5, 30);
      expect(g.filter(m, presence: true), m);
      expect(g.everPresent, isTrue);
    });

    test('presence false: sample contact does not count', () {
      final g = EcgPresenceGate();
      final out = g.filter(_contact(), presence: false);
      expect(out, hasLength(100));
      expect(out.any((c) => c), isFalse);
      expect(g.fellBack, isFalse);
    });

    test('presence false with no contact stays no contact', () {
      final g = EcgPresenceGate();
      expect(g.filter(_none(), presence: false), _none());
      expect(g.suspectRun, 0);
      expect(g.holdsFirstWindow, isFalse);
    });

    test('the veto is per packet: a presence-true packet right after is read '
        'as-is', () {
      final g = EcgPresenceGate();
      g.filter(_contact(), presence: false);
      final m = _contact(100, 5, 30);
      expect(g.filter(m, presence: true), m);
    });

    test('the length of an empty or short packet is kept', () {
      final g = EcgPresenceGate();
      expect(g.filter(const [], presence: false), isEmpty);
      expect(g.filter(_contact(7), presence: false), hasLength(7));
    });

    test('once presence has been seen the veto stays in force for the '
        'gesture: contact in a later presence-false packet never counts, '
        'however many', () {
      final g = EcgPresenceGate(fallbackPackets: 2);
      g.filter(_none(), presence: true);
      for (var i = 0; i < 6; i++) {
        expect(g.filter(_contact(), presence: false).any((c) => c), isFalse);
      }
      expect(g.fellBack, isFalse);
      expect(g.suspectRun, 0);
    });
  });

  group('the fallback', () {
    test('N consecutive presence-false packets with contact, presence never '
        'set: the veto lifts', () {
      final g = EcgPresenceGate(fallbackPackets: 4);
      for (var i = 1; i < 4; i++) {
        expect(g.filter(_contact(), presence: false).any((c) => c), isFalse,
            reason: 'packet $i is still vetoed');
        expect(g.fellBack, isFalse);
        expect(g.suspectRun, i);
        expect(g.holdsFirstWindow, isTrue);
      }
      final fourth = g.filter(_contact(), presence: false);
      expect(g.fellBack, isTrue);
      expect(fourth, _contact(), reason: 'the packet that triggers it counts');
      expect(g.holdsFirstWindow, isFalse);
    });

    test('after the fallback the same packet counts', () {
      final g = EcgPresenceGate(fallbackPackets: 2);
      g.filter(_contact(), presence: false);
      g.filter(_contact(), presence: false);
      final m = _contact(100, 5, 30);
      expect(g.filter(m, presence: false), m);
    });

    test('the fallback is sticky: a later presence-true packet does not '
        'restore the veto', () {
      final g = EcgPresenceGate(fallbackPackets: 2);
      g.filter(_contact(), presence: false);
      g.filter(_contact(), presence: false);
      g.filter(_none(), presence: true);
      final m = _contact();
      expect(g.filter(m, presence: false), m);
      expect(g.fellBack, isTrue);
    });

    test('the run must be consecutive: a packet without contact resets it',
        () {
      final g = EcgPresenceGate(fallbackPackets: 3);
      g.filter(_contact(), presence: false);
      g.filter(_contact(), presence: false);
      g.filter(_none(), presence: false);
      expect(g.suspectRun, 0);
      expect(g.holdsFirstWindow, isFalse);
      g.filter(_contact(), presence: false);
      g.filter(_contact(), presence: false);
      expect(g.fellBack, isFalse);
    });

    test('a presence-true packet means presence works: no fallback ever',
        () {
      final g = EcgPresenceGate(fallbackPackets: 2);
      g.filter(_contact(), presence: false);
      g.filter(_none(), presence: true);
      expect(g.everPresent, isTrue);
      expect(g.suspectRun, 0);
      for (var i = 0; i < 5; i++) {
        g.filter(_contact(), presence: false);
      }
      expect(g.fellBack, isFalse);
    });

    test('while the run builds, the first touch window is held; with no '
        'contact seen it is not', () {
      final g = EcgPresenceGate();
      expect(g.holdsFirstWindow, isFalse);
      g.filter(_contact(), presence: false);
      expect(g.holdsFirstWindow, isTrue);
    });
  });
}
