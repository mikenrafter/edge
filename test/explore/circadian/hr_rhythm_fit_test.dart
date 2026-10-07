// The experimental cosinor fit to recorded hourly HR (circadian explore,
// output 2 of 3). Strict admission, otherwise null with a named rejection.
//
// API under test (lib/explore/circadian/hr_rhythm_fit.dart):
//   fitHrRhythm(List<HourlyBin>) -> HrRhythm
//   gates as consts: kMinRhythmDays 7, kMinCoveredHoursPerDay 18,
//     kMinRealMinutesPerBin 10, kMinRhythmAmplitudeBpm (a floor, 1 to 2 bpm), kMaxPhaseSpreadHours 2.0
//   a bin is admitted with a non-null meanHr and realMinutes >= 10
//   a day is used with >= 18 admitted bins (local calendar day of the bin)
//   "days present" = distinct local days in the input, admitted or not:
//     fewer than 7 present -> tooFewDays;
//     >= 7 present but fewer than 7 usable -> lowCoverage
//   then amplitude < floor -> flat; then leave-one-day-out acrophase range
//     > 2 h -> unstable
//   acrophase/bathyphase are wall-clock (local) hours since midnight, the bin
//   value placed at the middle of its hour; bathyphase = acrophase + 12 h
//   coverage = mean fraction of the 24 bins admitted over the days used
//   a rejection carries null acrophase, bathyphase, amplitude and mesor

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/circadian/hr_rhythm_fit.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// HR at a clock hour (bin centre) for a cosine of [amp] peaking at [peakHour].
double _cos(double hourCentre, double mesor, double amp, double peakHour) =>
    mesor + amp * math.cos(2 * math.pi * (hourCentre - peakHour) / 24.0);

/// [days] days from 2026-05-04, every hour present unless [skipHours] has it.
/// [peak] picks the acrophase hour per day index; [amp] the amplitude per day.
List<HourlyBin> _days(
  int days, {
  double mesor = 60,
  double Function(int day)? amp,
  double Function(int day)? peak,
  Set<int> skipHours = const {},
  int realMinutes = 60,
}) {
  final out = <HourlyBin>[];
  for (var d = 0; d < days; d++) {
    for (var h = 0; h < 24; h++) {
      if (skipHours.contains(h)) continue;
      out.add(HourlyBin(
        hourStartLocal: DateTime(2026, 5, 4 + d, h),
        meanHr: _cos(h + 0.5, mesor, amp?.call(d) ?? 6, peak?.call(d) ?? 16),
        realMinutes: realMinutes,
      ));
    }
  }
  return out;
}

double _gapHours(Duration a, double hours) {
  var d = (a.inSeconds / 3600.0 - hours).abs() % 24;
  if (d > 12) d = 24 - d;
  return d;
}

void _expectNullOutputs(HrRhythm r) {
  expect(r.acrophaseClock, isNull);
  expect(r.bathyphaseClock, isNull);
  expect(r.amplitudeBpm, isNull);
  expect(r.mesorBpm, isNull);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('the admission gates are named and match the spec', () {
    expect(kMinRhythmDays, 7);
    expect(kMinCoveredHoursPerDay, 18);
    expect(kMinRealMinutesPerBin, 10);
    expect(kMaxPhaseSpreadHours, 2.0);
    // The floor must sit under the 2.3 bpm of the phase-jump fixture below, so
    // that fixture reaches the stability gate instead of stopping at flat.
    expect(kMinRhythmAmplitudeBpm, inInclusiveRange(1.0, 2.0));
  });

  group('admitted fit', () {
    test('14-day cosine (mesor 60, amplitude 6, peak 16:00) is recovered', () {
      final r = fitHrRhythm(_days(14));
      expect(r.rejection, isNull);
      expect(_gapHours(r.acrophaseClock!, 16), lessThanOrEqualTo(0.5));
      expect(_gapHours(r.bathyphaseClock!, 4), lessThanOrEqualTo(0.5));
      expect(r.amplitudeBpm!, closeTo(6.0, 0.5));
      expect(r.mesorBpm!, closeTo(60.0, 0.5));
      expect(r.daysUsed, 14);
      expect(r.coverage, greaterThan(0.95));
    });

    test('clock values are in [0, 24 h) and the trough is 12 h from the peak',
        () {
      final r = fitHrRhythm(_days(14, peak: (_) => 23));
      expect(r.rejection, isNull);
      for (final d in [r.acrophaseClock!, r.bathyphaseClock!]) {
        expect(d, greaterThanOrEqualTo(Duration.zero));
        expect(d, lessThan(const Duration(hours: 24)));
      }
      expect(_gapHours(r.acrophaseClock!, 23), lessThanOrEqualTo(0.5));
      expect(_gapHours(r.bathyphaseClock!, 11), lessThanOrEqualTo(0.5));
    });

    test('exactly 7 usable days is admitted', () {
      final r = fitHrRhythm(_days(7));
      expect(r.rejection, isNull);
      expect(r.daysUsed, 7);
    });

    test('20 covered hours a day is admitted and coverage says 20/24', () {
      final r = fitHrRhythm(_days(14, skipHours: {8, 9, 10, 11}));
      expect(r.rejection, isNull);
      expect(r.coverage, closeTo(20 / 24, 0.01));
      expect(_gapHours(r.acrophaseClock!, 16), lessThanOrEqualTo(0.5));
    });

    test('bins under 10 real minutes are ignored, even with a wild value', () {
      // Four hours a day (20 admitted bins, still >= 18) carry 9 real minutes
      // and a nonsense 250 bpm. They must not move the fit.
      final out = <HourlyBin>[];
      for (var d = 0; d < 14; d++) {
        for (var h = 0; h < 24; h++) {
          final thin = h >= 8 && h <= 11;
          out.add(HourlyBin(
            hourStartLocal: DateTime(2026, 5, 4 + d, h),
            meanHr: thin ? 250 : _cos(h + 0.5, 60, 6, 16),
            realMinutes: thin ? kMinRealMinutesPerBin - 1 : 60,
          ));
        }
      }
      final r = fitHrRhythm(out);
      expect(r.rejection, isNull);
      expect(r.amplitudeBpm!, closeTo(6.0, 0.5));
      expect(r.mesorBpm!, closeTo(60.0, 0.5));
      expect(_gapHours(r.acrophaseClock!, 16), lessThanOrEqualTo(0.5));
      expect(r.coverage, closeTo(20 / 24, 0.01));
    });

    test('exactly 10 real minutes is admitted (the gate is >=)', () {
      final r = fitHrRhythm(_days(14, realMinutes: kMinRealMinutesPerBin));
      expect(r.rejection, isNull);
      expect(r.daysUsed, 14);
    });

    test('a bin with real minutes but a null meanHr is not imputed', () {
      // 14 full days, but 8 hours a day have meanHr null: 16 admitted < 18.
      final out = [
        for (final b in _days(14))
          HourlyBin(
            hourStartLocal: b.hourStartLocal,
            meanHr: b.hourStartLocal.hour < 8 ? null : b.meanHr,
            realMinutes: b.realMinutes,
          ),
      ];
      final r = fitHrRhythm(out);
      expect(r.rejection, RhythmRejection.lowCoverage);
      _expectNullOutputs(r);
    });

    test('a 23-hour DST day is still usable and the phase is wall-clock', () {
      // 14 days across the US spring-forward (2026-03-08). The nonexistent
      // 02:00 hour has no bin. The signal peaks at 16:00 on the wall clock.
      final ny = tz.getLocation('America/New_York');
      final out = <HourlyBin>[];
      for (var d = 0; d < 14; d++) {
        for (var h = 0; h < 24; h++) {
          final t = tz.TZDateTime(ny, 2026, 3, 2 + d, h);
          if (t.hour != h) continue; // skipped by the clock change
          out.add(HourlyBin(
            hourStartLocal: t,
            meanHr: _cos(h + 0.5, 60, 6, 16),
            realMinutes: 60,
          ));
        }
      }
      final r = fitHrRhythm(out);
      expect(r.rejection, isNull);
      expect(r.daysUsed, 14);
      expect(_gapHours(r.acrophaseClock!, 16), lessThanOrEqualTo(0.5));
    });
  });

  group('rejections', () {
    test('6 days -> tooFewDays, with nothing guessed', () {
      final r = fitHrRhythm(_days(6));
      expect(r.rejection, RhythmRejection.tooFewDays);
      _expectNullOutputs(r);
    });

    test('no data at all -> tooFewDays', () {
      final r = fitHrRhythm(const []);
      expect(r.rejection, RhythmRejection.tooFewDays);
      expect(r.daysUsed, 0);
      _expectNullOutputs(r);
    });

    test('days with 15 covered hours are dropped; 11 good days remain', () {
      final out = [
        ..._days(11),
        // Three more days, each only 15 covered hours.
        for (var d = 11; d < 14; d++)
          for (var h = 0; h < 15; h++)
            HourlyBin(
              hourStartLocal: DateTime(2026, 5, 4 + d, h),
              meanHr: _cos(h + 0.5, 60, 6, 16),
              realMinutes: 60,
            ),
      ];
      final r = fitHrRhythm(out);
      expect(r.rejection, isNull);
      expect(r.daysUsed, 11);
    });

    test('18 covered hours is the edge: kept; 17 is dropped', () {
      List<HourlyBin> cover(int day, int hours) => [
            for (var h = 0; h < hours; h++)
              HourlyBin(
                hourStartLocal: DateTime(2026, 5, 4 + day, h),
                meanHr: _cos(h + 0.5, 60, 6, 16),
                realMinutes: 60,
              ),
          ];
      final keep = fitHrRhythm([for (var d = 0; d < 7; d++) ...cover(d, 18)]);
      expect(keep.rejection, isNull);
      expect(keep.daysUsed, 7);

      final drop = fitHrRhythm([for (var d = 0; d < 7; d++) ...cover(d, 17)]);
      expect(drop.rejection, RhythmRejection.lowCoverage);
      _expectNullOutputs(drop);
    });

    test('fewer than 7 days left after the coverage gate -> lowCoverage', () {
      final out = [
        ..._days(6),
        for (var d = 6; d < 12; d++)
          for (var h = 0; h < 15; h++)
            HourlyBin(
              hourStartLocal: DateTime(2026, 5, 4 + d, h),
              meanHr: _cos(h + 0.5, 60, 6, 16),
              realMinutes: 60,
            ),
      ];
      final r = fitHrRhythm(out);
      expect(r.rejection, RhythmRejection.lowCoverage);
      _expectNullOutputs(r);
    });

    test('every bin under 10 real minutes -> lowCoverage, not a fit', () {
      final r = fitHrRhythm(_days(14, realMinutes: kMinRealMinutesPerBin - 1));
      expect(r.rejection, RhythmRejection.lowCoverage);
      _expectNullOutputs(r);
    });

    test('a flat signal -> flat', () {
      // 60 bpm with +-0.3 bpm of deterministic jitter; amplitude far below
      // the floor.
      final out = [
        for (var d = 0; d < 14; d++)
          for (var h = 0; h < 24; h++)
            HourlyBin(
              hourStartLocal: DateTime(2026, 5, 4 + d, h),
              meanHr: 60 + 0.3 * math.sin(d * 7.1 + h * 3.7),
              realMinutes: 60,
            ),
      ];
      final r = fitHrRhythm(out);
      expect(r.rejection, RhythmRejection.flat);
      _expectNullOutputs(r);
    });

    test('a dead-flat constant -> flat', () {
      final r = fitHrRhythm(_days(14, amp: (_) => 0));
      expect(r.rejection, RhythmRejection.flat);
      _expectNullOutputs(r);
    });

    test('a clean cosine with amplitude just under the floor -> flat', () {
      final r = fitHrRhythm(_days(14, amp: (_) => kMinRhythmAmplitudeBpm * 0.8));
      expect(r.rejection, RhythmRejection.flat);
      _expectNullOutputs(r);
    });

    test('a phase jump halfway -> unstable', () {
      // 8 days: the first four peak at 16:00, the last four at 07:00 (nine
      // hours earlier). Whole-record amplitude is 6 cos(67.5 deg) = 2.3 bpm,
      // above the floor, but leaving one day out swings the acrophase by
      // about 2.5 h, over the 2 h limit. (A clean 12 h jump would cancel to
      // a flat signal instead.)
      final r = fitHrRhythm(_days(8, peak: (d) => d < 4 ? 16 : 7));
      expect(r.rejection, RhythmRejection.unstable);
      _expectNullOutputs(r);
    });

    // Sol P2 (hr_rhythm_fit.dart:130): leave-one-out barely moves when half
    // the days sit at each of two phases, so it admits a nine-hour phase
    // change as one rhythm (fitted peak 11:30, amplitude 2.3, LOO spread 1.4 h,
    // matching neither period). Needs a day-to-day consistency check.
    test('14 days, 7 peaking at 16:00 then 7 at 07:00 -> unstable', () {
      final r = fitHrRhythm(_days(14, amp: (_) => 6, peak: (d) => d < 7 ? 16 : 7));
      expect(r.rejection, RhythmRejection.unstable);
      _expectNullOutputs(r);
    });

    test('a steady daily phase wobble inside 2 h stays admitted', () {
      // +-0.5 h alternating day to day: well inside the limit.
      final r = fitHrRhythm(_days(14, peak: (d) => d.isEven ? 15.5 : 16.5));
      expect(r.rejection, isNull);
      expect(_gapHours(r.acrophaseClock!, 16), lessThanOrEqualTo(0.5));
    });

    test('a rejection never reports a number as a guess', () {
      for (final bins in [
        _days(3),
        _days(14, realMinutes: 2),
        _days(14, amp: (_) => 0.2),
        _days(8, peak: (d) => d < 4 ? 16 : 7),
      ]) {
        final r = fitHrRhythm(bins);
        expect(r.rejection, isNotNull);
        _expectNullOutputs(r);
      }
    });
  });
}
