// Parsing and gating of one night of the existing cardiac-pattern detector.
//
// Envelope shapes below are the persisted `respiration.cvhr_apnea` metric
// (analytics Metric.toJson around CvhrResult.toJson), including a present one
// captured from `deriveDayBundle` on a synthetic six hour night. Absent is
// `"value": "—"` plus a note. The rule under test: absent is NOT zero.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_night.dart';

/// Captured from the real pipeline (6 h of beats with a 70 s oscillation).
const String _realNote =
    'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
    'single-night CVHR has substantial night-to-night variability, interpret '
    'as a trend over multiple nights';

Map<String, dynamic> _realEnvelope() => {
      'value': {
        'cycle_count': 309,
        'cvhr_per_hour': 51.501797,
        'analyzed_hours': 5.999791,
        'mean_depth_ms': 130.413449,
        'mean_width_sec': 25.964401,
        'depth_quartiles_ms': [130.576931, 130.591163, 130.598669],
        'width_quartiles_sec': [26.0, 26.0, 26.0],
      },
      'confidence': 0.85,
      'tier': 'HIGH',
      'inputs_used': ['rr_cleaned', 'beat_times'],
      'note': _realNote,
    };

/// A present envelope with [cycles] over [hours] analysed hours.
Map<String, dynamic> _present(int cycles, double hours, {String? note}) => {
      'value': {
        'cycle_count': cycles,
        'cvhr_per_hour': hours > 0 ? cycles / hours : 0.0,
        'analyzed_hours': hours,
        'mean_depth_ms': cycles == 0 ? null : 90.0,
        'mean_width_sec': cycles == 0 ? null : 30.0,
        'depth_quartiles_ms': null,
        'width_quartiles_sec': null,
      },
      'confidence': 0.85,
      'tier': 'HIGH',
      'inputs_used': ['rr_cleaned', 'beat_times'],
      'note': ?note,
    };

Map<String, dynamic> _absent(String note) => {
      'value': '—',
      'confidence': 0,
      'tier': 'HIGH',
      'inputs_used': ['rr_cleaned', 'beat_times'],
      'note': note,
    };

void main() {
  group('a present envelope', () {
    test('keeps the detector count, hours, coverage and note as stored', () {
      final n = fromCvhrEnvelope('2026-10-07', _realEnvelope(),
          sleepHours: 6.5);
      expect(n.dayId, '2026-10-07');
      expect(n.cycleCount, 309);
      expect(n.analysedHours, closeTo(5.999791, 1e-9));
      expect(n.coverage, closeTo(5.999791 / 6.5, 1e-9));
      expect(n.cyclesPerHour, closeTo(309 / 5.999791, 1e-6));
      expect(n.detectorNote, _realNote);
      expect(n.exclusions, isEmpty);
      expect(n.admitted, isTrue);
    });

    test('with N cycles reports exactly N', () {
      for (final c in [1, 7, 23, 120]) {
        final n = fromCvhrEnvelope('d', _present(c, 6.0), sleepHours: 7.0);
        expect(n.cycleCount, c);
        expect(n.admitted, isTrue, reason: '$c cycles over 6 of 7 hours');
      }
    });

    test('with 0 cycles is 0, analysed, and admitted', () {
      final n = fromCvhrEnvelope('d', _present(0, 5.5), sleepHours: 6.0);
      expect(n.cycleCount, 0);
      expect(n.cycleCount, isNotNull);
      expect(n.analysedHours, 5.5);
      expect(n.cyclesPerHour, 0);
      expect(n.exclusions, isEmpty);
      expect(n.admitted, isTrue);
    });
  });

  group('an absent envelope is not analysed, never 0', () {
    test('the stored absent shape', () {
      final n = fromCvhrEnvelope(
          'd', _absent('too few beats for a CVHR screen (need ≥60)'),
          sleepHours: 7.0);
      expect(n.cycleCount, isNull);
      expect(n.analysedHours, isNull);
      expect(n.coverage, isNull);
      expect(n.cyclesPerHour, isNull);
      expect(n.exclusions, ['not analysed']);
      expect(n.detectorNote, 'too few beats for a CVHR screen (need ≥60)');
      expect(n.admitted, isFalse);
    });

    test('a null envelope (nothing persisted for the day)', () {
      final n = fromCvhrEnvelope('d', null, sleepHours: 7.0);
      expect(n.cycleCount, isNull);
      expect(n.exclusions, ['not analysed']);
      expect(n.detectorNote, isNull);
      expect(n.admitted, isFalse);
    });

    test('absent stays absent whatever the sleep hours are', () {
      for (final h in <double?>[null, 0, 4, 9]) {
        final n = fromCvhrEnvelope('d', _absent('x'), sleepHours: h);
        expect(n.cycleCount, isNull, reason: 'sleepHours=$h');
        expect(n.coverage, isNull, reason: 'sleepHours=$h');
      }
    });
  });

  group('a malformed envelope is not analysed and never throws', () {
    final cases = <String, Object?>{
      'a string': 'garbage',
      'a number': 42,
      'a list': <Object?>[1, 2, 3],
      'an empty map': <String, dynamic>{},
      'value is a number': {'value': 12},
      'value is an empty map': {'value': <String, dynamic>{}},
      'cycle_count is text': {
        'value': {'cycle_count': 'many', 'analyzed_hours': 6.0},
      },
      'cycle_count is negative': {
        'value': {'cycle_count': -3, 'analyzed_hours': 6.0},
      },
      'cycle_count is fractional': {
        'value': {'cycle_count': 2.5, 'analyzed_hours': 6.0},
      },
      'analyzed_hours missing': {
        'value': {'cycle_count': 3},
      },
      'analyzed_hours is NaN': {
        'value': {'cycle_count': 3, 'analyzed_hours': double.nan},
      },
      'analyzed_hours is negative': {
        'value': {'cycle_count': 3, 'analyzed_hours': -1.0},
      },
      'analyzed_hours is infinite': {
        'value': {'cycle_count': 3, 'analyzed_hours': double.infinity},
      },
    };
    for (final e in cases.entries) {
      test(e.key, () {
        late PulsePatternNight n;
        expect(() => n = fromCvhrEnvelope('d', e.value, sleepHours: 7.0),
            returnsNormally);
        expect(n.cycleCount, isNull);
        expect(n.analysedHours, isNull);
        expect(n.cyclesPerHour, isNull);
        expect(n.exclusions, ['not analysed']);
        expect(n.admitted, isFalse);
      });
    }
  });

  group('admission gates (proposed engineering gates, not clinical)', () {
    test('3.9 analysed hours is under the 4 hour gate', () {
      final n = fromCvhrEnvelope('d', _present(5, 3.9), sleepHours: 4.0);
      expect(n.coverage, closeTo(0.975, 1e-9), reason: 'coverage is fine');
      expect(n.exclusions, ['under 4 analysed hours']);
      expect(n.admitted, isFalse);
    });

    test('79% coverage is under the 80% gate', () {
      final n = fromCvhrEnvelope('d', _present(5, 5.53), sleepHours: 7.0);
      expect(n.coverage, closeTo(0.79, 1e-9));
      expect(n.exclusions, ['coverage under 80%']);
      expect(n.admitted, isFalse);
    });

    test('exactly 4.0 hours at exactly 80% is admitted (both inclusive)', () {
      final n = fromCvhrEnvelope('d', _present(5, 4.0), sleepHours: 5.0);
      expect(n.coverage, closeTo(0.8, 1e-12));
      expect(n.exclusions, isEmpty);
      expect(n.admitted, isTrue);
    });

    test('failing both gates names both, hours first', () {
      final n = fromCvhrEnvelope('d', _present(5, 3.0), sleepHours: 8.0);
      expect(n.exclusions, ['under 4 analysed hours', 'coverage under 80%']);
      expect(n.admitted, isFalse);
    });

    test('unknown sleep hours cannot be assumed to be full coverage', () {
      for (final h in <double?>[null, 0.0, -2.0]) {
        final n = fromCvhrEnvelope('d', _present(5, 6.0), sleepHours: h);
        expect(n.coverage, isNull, reason: 'sleepHours=$h');
        expect(n.admitted, isFalse, reason: 'sleepHours=$h');
        expect(n.exclusions, isNotEmpty, reason: 'sleepHours=$h');
        expect(n.exclusions.any((s) => s.contains('coverage')), isTrue);
        expect(n.exclusions, isNot(contains('not analysed')),
            reason: 'it WAS analysed; only the denominator is unknown');
      }
    });

    // EDITED (fix round, Sol P2 "coverage divides incompatible intervals"):
    // this test used to assert `coverage == 1.0` and `admitted`, i.e. it
    // encoded the silent clamp at pulse_pattern_night.dart:119. The second
    // argument is now the sleep WINDOW length (onset to offset), and analysis
    // longer than the window is flagged, never clamped.
    test('analysed hours above the sleep window are flagged, not clamped', () {
      final n = fromCvhrEnvelope('d', _present(2, 6.1), sleepHours: 6.0);
      expect(n.exclusions, contains('analysis longer than the sleep window'));
      expect(n.admitted, isFalse);
      expect(n.coverage == null || n.coverage! > 1.0, isTrue,
          reason: 'coverage must not be silently clamped to 1.0');
    });

    // NEW (Sol P2): reviewer scenario, an 8 h window with 4 h analysed. The
    // loader passes the window length, so coverage is 4 / 8.
    test('4 analysed hours over an 8 hour window is 50% coverage, excluded',
        () {
      final n = fromCvhrEnvelope('d', _present(5, 4.0), sleepHours: 8.0);
      expect(n.coverage, closeTo(0.5, 1e-12));
      expect(n.exclusions, ['coverage under 80%']);
      expect(n.admitted, isFalse);
    });

    // NEW (Sol P2): a window much longer than the analysis, exactly equal,
    // is full coverage (not "longer than the window").
    test('analysis equal to the window is 100% and admitted', () {
      final n = fromCvhrEnvelope('d', _present(5, 6.0), sleepHours: 6.0);
      expect(n.coverage, 1.0);
      expect(n.exclusions, isEmpty);
      expect(n.admitted, isTrue);
    });
  });

  group('cyclesPerHour', () {
    test('is the stored cycles over the analysed hours', () {
      final n = fromCvhrEnvelope('d', _present(12, 6.0), sleepHours: 6.0);
      expect(n.cyclesPerHour, closeTo(2.0, 1e-12));
    });

    test('is null when the hours are null (not analysed)', () {
      expect(fromCvhrEnvelope('d', null).cyclesPerHour, isNull);
      expect(fromCvhrEnvelope('d', _absent('x')).cyclesPerHour, isNull);
    });

    test('is null, not infinite, when analysed hours are 0', () {
      final n = fromCvhrEnvelope('d', _present(0, 0.0), sleepHours: 6.0);
      expect(n.analysedHours, 0);
      expect(n.cyclesPerHour, isNull);
      expect(n.exclusions, contains('under 4 analysed hours'));
    });
  });
}
