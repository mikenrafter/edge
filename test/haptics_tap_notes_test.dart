// Taps -> notes -> commands.
//
// A BuzzSequence is press starts, hold durations and release gaps in ms. The
// transcriber's grid is one sixteenth = 125 ms; a hold becomes the nearest
// allowed note length (a quick tap is a 16th), a release gap becomes rests
// (nothing when it rounds to zero units), and the plan is compiled with no
// loudness cost because taps carry none.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

String _notes(BuzzSequence s, {int unitMs = 125}) =>
    notesFromTaps(s, unitMs: unitMs).join(' ');

/// One press of [holdMs] only.
BuzzSequence _hold(int holdMs) => BuzzSequence([0], durationsMs: [holdMs]);

/// Two quick taps whose release gap is [gapMs].
BuzzSequence _gap(int gapMs) => BuzzSequence([0, gapMs]);

void main() {
  group('notesFromTaps: holds', () {
    test('a quick tap (no hold) is a 16th, any loudness', () {
      expect(_notes(BuzzSequence([0])), 'N1*');
    });

    test('a hold shorter than half a unit still floors at one unit', () {
      expect(_notes(_hold(40)), 'N1*');
      expect(_notes(_hold(60)), 'N1*');
    });

    test('holds round to the nearest allowed length', () {
      const cases = {
        125: 'N1*', // 1 unit
        200: 'N2*', // 1.6 -> 2
        250: 'N2*',
        375: 'N3*', // dotted eighth
        500: 'N4*',
        750: 'N6*', // dotted quarter
        1000: 'N8*',
        1125: 'N8*', // 9 units: 8 is nearer than 12
        1375: 'N12*', // 11 units: 12 is nearer than 8
        1500: 'N12*', // dotted half
      };
      cases.forEach((hold, code) {
        expect(_notes(_hold(hold)), code, reason: 'hold $hold ms');
      });
    });

    test('a hold longer than the longest note stays at the longest', () {
      expect(_notes(_hold(2000)), 'N12*');
      expect(_notes(_hold(5000)), 'N12*');
    });

    test('every note is any loudness (*) and every rest has no dynamic', () {
      final e = notesFromTaps(
        BuzzSequence([0, 1000], durationsMs: [500, 250]),
      );
      for (final x in e) {
        expect(x.dynamic, x.note ? PatternDynamic.any : isNull);
      }
    });
  });

  group('notesFromTaps: release gaps', () {
    test('a gap rounds to units and becomes one rest when it is allowed', () {
      expect(_notes(_gap(125)), 'N1* R1 N1*');
      expect(_notes(_gap(250)), 'N1* R2 N1*');
      expect(_notes(_gap(375)), 'N1* R3 N1*');
      expect(_notes(_gap(500)), 'N1* R4 N1*');
      expect(_notes(_gap(1000)), 'N1* R8 N1*');
      expect(_notes(_gap(1500)), 'N1* R12 N1*');
    });

    test('a gap that is not one length splits greedily, largest first', () {
      expect(_notes(_gap(625)), 'N1* R4 R1 N1*'); // 5 units
      expect(_notes(_gap(875)), 'N1* R6 R1 N1*'); // 7 units
      expect(_notes(_gap(1625)), 'N1* R12 R1 N1*'); // 13 units
      expect(_notes(_gap(1750)), 'N1* R12 R2 N1*'); // 14 units
      expect(_notes(_gap(2000)), 'N1* R12 R4 N1*'); // 16 units
    });

    test('a gap that rounds to zero units adds no rest', () {
      expect(_notes(_gap(1)), 'N1* N1*');
      expect(_notes(_gap(40)), 'N1* N1*');
      expect(_notes(_gap(70)), 'N1* R1 N1*', reason: '0.56 rounds to 1');
    });

    test('the gap is measured from the release, not the press start', () {
      // Press 0 held 500 ms, next press at 1000: a 500 ms gap, not 1000.
      expect(
        _notes(BuzzSequence([0, 1000], durationsMs: [500, 250])),
        'N4* R4 N2*',
      );
    });

    test('three presses', () {
      expect(
        _notes(BuzzSequence([0, 600, 1500], durationsMs: [100, 300, 0])),
        'N1* R4 N2* R4 R1 N1*',
      );
    });
  });

  group('notesFromTaps: unit length', () {
    test('another unitMs rescales holds and gaps', () {
      final s = BuzzSequence([0, 1000], durationsMs: [500, 250]);
      expect(_notes(s, unitMs: 250), 'N2* R2 N1*');
      expect(_notes(s, unitMs: 125), 'N4* R4 N2*');
    });

    test('default unit is 125 ms', () {
      final s = BuzzSequence([0, 1000], durationsMs: [500, 250]);
      expect(notesFromTaps(s), notesFromTaps(s, unitMs: 125));
    });
  });

  group('notesFromTaps: purity', () {
    test('same sequence, same notes; the sequence is untouched', () {
      final s = BuzzSequence([0, 700, 1700], durationsMs: [300, 200, 900]);
      final before = s.toJson();
      expect(notesFromTaps(s), notesFromTaps(s));
      expect(s.toJson(), before);
    });

    test('every produced length is an allowed length', () {
      for (var gap = 1; gap <= 2000; gap += 37) {
        for (final e in notesFromTaps(
          BuzzSequence([0, gap + 300], durationsMs: [300, 0]),
        )) {
          expect(kPatternLengths, contains(e.length));
        }
      }
    });
  });

  group('planForTaps', () {
    final mg = HapticDeviceProfile.whoopMg;

    test('compiles the taps with no loudness cost', () {
      // A half-second hold is N4*. No MG phrase feels mf for four cells, so
      // with the default weight it would be approximate; taps carry no
      // loudness, so it must be exact.
      final plan = planForTaps(_hold(500), mg)!;
      expect(plan.exact, isTrue);
      expect(plan.cost, 0);
    });

    test('equals compile(notesFromTaps, dynamicWeight: 0) for the same flag',
        () {
      for (final s in [
        _hold(500),
        BuzzSequence([0, 500]),
        BuzzSequence([0, 900], durationsMs: [500, 500]),
        BuzzSequence([0, 1500], durationsMs: [500, 1000]),
      ]) {
        final want = compile(
          notesFromTaps(s),
          mg,
          dynamicWeight: 0,
        )!;
        final got = planForTaps(s, mg)!;
        expect(got.summary, want.summary, reason: '$s');
        expect(got.cost, want.cost);
        expect(got.exact, want.exact);
        expect([for (final x in got.steps) x.phrase.id],
            [for (final x in want.steps) x.phrase.id]);
        expect([for (final x in got.steps) x.delayMs],
            [for (final x in want.steps) x.delayMs]);
      }
    });

    test('the unstable parts are always considered', () {
      // Two half-second holds with a 125 ms release gap: N4* R1 N4*. One
      // unit of silence between commands is only measured on the unstable
      // 100 ms row, and it is taken because it fits where no stable row does.
      final plain = BuzzSequence([0, 625], durationsMs: [500, 500]);
      final plan = planForTaps(plain, mg)!;
      expect(plan.exact, isTrue);
      expect(plan.usesUnstable, isTrue);
      expect(plan.steps[1].delayMs, 100);
    });

    test('a single quick tap still produces a plan', () {
      final plan = planForTaps(BuzzSequence([0]), mg);
      expect(plan, isNotNull);
      expect(plan!.steps, isNotEmpty);
    });

    // Seven quick taps 1.9 s apart: about 14 s of rhythm.
    final longRhythm = BuzzSequence([for (var i = 0; i < 7; i++) i * 1900]);

    test('over the runtime cap there is no plan by default', () {
      expect(planForTaps(longRhythm, mg), isNull);
    });

    test('the cap is kMaxHapticRuntime and a parameter overrides it', () {
      expect(planForTaps(longRhythm, mg, maxRuntime: null), isNotNull);
      expect(
          planForTaps(longRhythm, mg, maxRuntime: const Duration(seconds: 30)),
          isNotNull);
      expect(
          planForTaps(_hold(500), mg, maxRuntime: const Duration(milliseconds: 100)),
          isNull);
      final under = planForTaps(BuzzSequence([0, 1900, 3800]), mg);
      expect(under, isNotNull);
      expect(under!.runtimeMs, lessThanOrEqualTo(kMaxHapticRuntime.inMilliseconds));
    });
  });
}