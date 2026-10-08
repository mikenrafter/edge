// Design 04 phase 1 (RED) - item 1: the shared ECG outcome, decided in one
// place (lib/ecg/ecg_outcome.dart). Pure Dart.
//
// The matrix under test is R1 (Revision 2) with R1' / R1'' (mask_any |
// unreadable_mask):
//   partial                          -> partial (no rhythm label)
//   ANY mask bit (incl. bits 4-7)    -> notReadable + reasons
//   unknown result code              -> notReadable
//   result 0 / 2                     -> notReadable
//   result 6                         -> inconclusive
//   HR 0 / 255 / none where needed   -> notReadable ("no heart rate")
//   HR outside the code's range      -> notReadable (assumption: categoryFor
//                                       says unreadable; see the report)
//   otherwise                        -> bandResult(category) + the caveat
// HR source is averageHr; live HR never decides.
//
// ASSUMED API (lib/ecg/ecg_outcome.dart): ecgOutcomeOf(resultCode, avgHr, mask,
// partial), ecgOutcome(EcgReading), EcgOutcomeKind, EcgReason(id, arg),
// EcgReasonId, EcgCaveat.bandReportedQualityUnchecked.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';

import 'support/cardio_fixtures.dart';

EcgOutcome _o(int code, int? hr, {int mask = 0, bool partial = false}) =>
    ecgOutcomeOf(resultCode: code, avgHr: hr, mask: mask, partial: partial);

void main() {
  group('categoryFor (the table the outcome is built on)', () {
    test('result 3 with heart rate 0 is NOT "low heart rate": no rate is no '
        'rate', () {
      expect(categoryFor(3, 0), EcgCategory.unreadable);
    });

    test('result 3 at 1..50 bpm is low heart rate, at 51 it is not', () {
      expect(categoryFor(3, 1), EcgCategory.lowHeartRate);
      expect(categoryFor(3, 50), EcgCategory.lowHeartRate);
      expect(categoryFor(3, 51), EcgCategory.unreadable);
    });
  });

  group('the heart-rate boundaries, codes 1, 3, 4, 5', () {
    // (code, hr, expected band category or null = notReadable)
    const cases = <(int, int, EcgCategory?)>[
      // code 1: regular only at 51..99
      (1, 50, null),
      (1, 51, EcgCategory.sinusRhythm),
      (1, 99, EcgCategory.sinusRhythm),
      (1, 100, null),
      // code 3: low heart rate at <=50
      (3, 50, EcgCategory.lowHeartRate),
      (3, 51, null),
      // code 4: 51..99 / 100..150 / 151..200
      (4, 50, null),
      (4, 51, EcgCategory.possibleAfib),
      (4, 99, EcgCategory.possibleAfib),
      (4, 100, EcgCategory.afibHighHeartRate),
      (4, 150, EcgCategory.afibHighHeartRate),
      (4, 151, EcgCategory.highHeartRate),
      (4, 200, EcgCategory.highHeartRate),
      (4, 201, null),
      // code 5: 100..150 / 151..200
      (5, 99, null),
      (5, 100, EcgCategory.highHeartRateNoAfib),
      (5, 150, EcgCategory.highHeartRateNoAfib),
      (5, 151, EcgCategory.highHeartRate),
      (5, 200, EcgCategory.highHeartRate),
      (5, 201, null),
    ];
    for (final (code, hr, want) in cases) {
      test('result $code at $hr bpm -> ${want?.name ?? 'notReadable'}', () {
        final o = _o(code, hr);
        if (want == null) {
          expect(o.kind, EcgOutcomeKind.notReadable);
          expect(o.bandResult, isNull, reason: 'no rhythm label');
          expect(o.reasons, isNotEmpty);
        } else {
          expect(o.kind, EcgOutcomeKind.bandResult);
          expect(o.bandResult, want);
        }
        expect(o.avgHr, hr, reason: 'the raw band value is preserved');
        expect(o.resultCode, code);
      });
    }
  });

  group('no heart rate where the mapping needs one', () {
    for (final code in [1, 3, 4, 5]) {
      for (final hr in <int?>[0, 255, null]) {
        test('result $code with heart rate $hr is notReadable, reason '
            '"no heart rate reported"', () {
          final o = _o(code, hr);
          expect(o.kind, EcgOutcomeKind.notReadable);
          expect(o.bandResult, isNull);
          expect(o.reasons, contains(const EcgReason(EcgReasonId.noHeartRate)));
        });
      }
    }

    test('result 6 does not need a rate: inconclusive at heart rate 0', () {
      expect(_o(6, 0).kind, EcgOutcomeKind.inconclusive);
      expect(_o(6, null).kind, EcgOutcomeKind.inconclusive);
      expect(_o(6, 255).kind, EcgOutcomeKind.inconclusive);
    });
  });

  group('result codes', () {
    test('result 0 and 2 are notReadable whatever the rate', () {
      for (final code in [0, 2]) {
        for (final hr in <int?>[0, 77, 255, null]) {
          final o = _o(code, hr);
          expect(o.kind, EcgOutcomeKind.notReadable, reason: '$code/$hr');
          expect(o.bandResult, isNull);
          expect(
            o.reasons,
            contains(EcgReason(EcgReasonId.bandUnreadableResult, code)),
          );
        }
      }
    });

    test('result 6 is inconclusive with no rhythm label', () {
      final o = _o(6, 77);
      expect(o.kind, EcgOutcomeKind.inconclusive);
      expect(o.bandResult, isNull);
    });

    test('an unknown result code is notReadable and says which code', () {
      for (final code in [7, 9, 100, 255]) {
        final o = _o(code, 77);
        expect(o.kind, EcgOutcomeKind.notReadable, reason: '$code');
        expect(o.bandResult, isNull);
        expect(
          o.reasons,
          contains(EcgReason(EcgReasonId.unknownResultCode, code)),
        );
      }
    });
  });

  group('the mask (R1\' / R1\'\')', () {
    test('any single known bit overrides a "regular rhythm" verdict', () {
      const bits = {
        0x01: EcgReasonId.lowAmplitude,
        0x02: EcgReasonId.significantNoise,
        0x04: EcgReasonId.unstableSignal,
        0x08: EcgReasonId.notEnoughData,
      };
      for (final e in bits.entries) {
        final o = _o(1, 77, mask: e.key);
        expect(o.kind, EcgOutcomeKind.notReadable, reason: 'mask ${e.key}');
        expect(o.bandResult, isNull);
        expect(o.reasons, [EcgReason(e.value)]);
      }
    });

    test('unknown bits 4-7 also make it notReadable, each reported by bit '
        'index', () {
      for (var bit = 4; bit <= 7; bit++) {
        final o = _o(1, 77, mask: 1 << bit);
        expect(o.kind, EcgOutcomeKind.notReadable, reason: 'bit $bit');
        expect(o.reasons, [EcgReason(EcgReasonId.unknownBandReasonBit, bit)]);
      }
      expect(
        _o(1, 77, mask: 0xF0).reasons,
        [for (var b = 4; b <= 7; b++) EcgReason(EcgReasonId.unknownBandReasonBit, b)],
      );
    });

    test('reasons come in bit order, known bits first, then unknown', () {
      expect(_o(1, 77, mask: 0x1B).reasons, [
        const EcgReason(EcgReasonId.lowAmplitude),
        const EcgReason(EcgReasonId.significantNoise),
        const EcgReason(EcgReasonId.notEnoughData),
        const EcgReason(EcgReasonId.unknownBandReasonBit, 4),
      ]);
    });

    test('a set mask beats result 6: notReadable, not inconclusive', () {
      expect(_o(6, 77, mask: 2).kind, EcgOutcomeKind.notReadable);
    });

    test('mask reasons and a code reason accumulate', () {
      final o = _o(1, 0, mask: 2);
      expect(o.kind, EcgOutcomeKind.notReadable);
      expect(o.reasons, containsAll([
        const EcgReason(EcgReasonId.significantNoise),
        const EcgReason(EcgReasonId.noHeartRate),
      ]));
    });

    test('mask 0 changes nothing', () {
      expect(_o(1, 77, mask: 0).kind, EcgOutcomeKind.bandResult);
    });
  });

  group('partial', () {
    test('partial wins: no rhythm label, whatever the band bytes say', () {
      for (final (code, hr) in [(1, 77), (4, 120), (6, 70), (2, 0), (9, 5)]) {
        final o = _o(code, hr, partial: true);
        expect(o.kind, EcgOutcomeKind.partial, reason: '$code/$hr');
        expect(o.bandResult, isNull);
      }
    });
  });

  group('the caveat', () {
    test('a band result carries "the app has not checked this recording\'s '
        'quality" and no other kind carries it', () {
      expect(
        _o(1, 77).caveats,
        contains(EcgCaveat.bandReportedQualityUnchecked),
      );
      for (final o in [
        _o(1, 77, mask: 2),
        _o(6, 77),
        _o(2, 77),
        _o(1, 77, partial: true),
        _o(9, 77),
      ]) {
        expect(o.caveats, isNot(contains(EcgCaveat.bandReportedQualityUnchecked)),
            reason: '${o.kind}');
      }
    });

    test('a plain band result has no reasons', () {
      expect(_o(1, 77).reasons, isEmpty);
    });
  });

  group('ecgOutcome(reading): saved rows', () {
    test('mask_any | unreadable_mask: a TERMINAL-ONLY mask is never missed',
        () {
      final r = cardioReading(unreadableMask: 2, maskAny: null);
      expect(ecgOutcome(r).kind, EcgOutcomeKind.notReadable);
      expect(ecgOutcome(r).mask, 2);
    });

    test('mask_any alone (clean terminal, noisy second inside the window) is '
        'notReadable', () {
      final r = cardioReading(unreadableMask: 0, maskAny: 4);
      expect(ecgOutcome(r).kind, EcgOutcomeKind.notReadable);
      expect(ecgOutcome(r).reasons, [const EcgReason(EcgReasonId.unstableSignal)]);
    });

    test('both masks are OR-ed', () {
      final r = cardioReading(unreadableMask: 1, maskAny: 2);
      expect(ecgOutcome(r).mask, 3);
      expect(ecgOutcome(r).reasons, [
        const EcgReason(EcgReasonId.lowAmplitude),
        const EcgReason(EcgReasonId.significantNoise),
      ]);
    });

    test('a legacy row (NULL mask_any) with a clean mask is judged on the '
        'terminal fields alone', () {
      expect(ecgOutcome(cardioReading()).kind, EcgOutcomeKind.bandResult);
      expect(ecgOutcome(cardioReading()).bandResult, EcgCategory.sinusRhythm);
    });

    test('the outcome reads result_code and avg_hr, NOT the stored category: a '
        'row saved by the old live-HR path is re-judged', () {
      // Old code stored sinusRhythm from the live rate; the average rate was 120.
      final r = cardioReading(category: EcgCategory.sinusRhythm, avgHr: 120);
      final o = ecgOutcome(r);
      expect(o.kind, EcgOutcomeKind.notReadable);
      expect(o.bandResult, isNull);
      expect(r.category, EcgCategory.sinusRhythm,
          reason: 'the stored raw value is untouched');
    });

    test('a partial row is partial', () {
      expect(ecgOutcome(partialAt(kC0 + 12)).kind, EcgOutcomeKind.partial);
    });

    test('a row with a NULL avg_hr (the controller stores "none" as NULL) '
        'needs-a-rate codes are notReadable "no heart rate"', () {
      final o = ecgOutcome(cardioReading(avgHr: null));
      expect(o.kind, EcgOutcomeKind.notReadable);
      expect(o.reasons, contains(const EcgReason(EcgReasonId.noHeartRate)));
    });

    test('the raw band values ride along untouched', () {
      final o = ecgOutcome(cardioReading(resultCode: 4, avgHr: 120));
      expect(o.resultCode, 4);
      expect(o.avgHr, 120);
      expect(o.bandResult, EcgCategory.afibHighHeartRate);
    });
  });

  group('one source (AGENTS 3.8): capture, history, detail, export and coach '
      'all read ecgOutcome', () {
    String src(String p) => File(p).readAsStringSync();

    test('every consumer calls ecgOutcome(', () {
      for (final f in [
        'lib/ui2/screens/ecg.dart', // capture body, history row, detail
        'lib/ecg/ecg_export.dart',
        'lib/coach/coach_actions.dart',
        'lib/ecg/ecg_controller.dart', // the capture state's outcome
      ]) {
        expect(src(f).contains('ecgOutcome('), isTrue, reason: f);
      }
    });

    test('nothing but the outcome and the table calls categoryFor', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.contains('/l10n/')) continue;
        final text = e.readAsStringSync();
        if (text.contains('categoryFor(')) hits.add(e.path);
      }
      hits.sort();
      expect(hits, [
        'lib/ecg/ecg_models.dart', // the table
        'lib/ecg/ecg_outcome.dart', // the one reader
      ], reason: 'the reducer (ecg_policy.dart) must decide through the same '
          'function, not its own call');
    });

    test('no screen or tool re-derives a verdict from the stored category',
        () {
      for (final f in ['lib/ui2/screens/ecg.dart', 'lib/coach/coach_actions.dart']) {
        final text = src(f);
        expect(text.contains('categoryFor('), isFalse, reason: f);
        expect(text.contains('r.category =='), isFalse, reason: f);
        expect(text.contains('reading.category =='), isFalse, reason: f);
      }
    });
  });
}
