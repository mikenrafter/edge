// Observed sleep timing and variability (circadian explore, output 1 of 3).
//
// API under test (lib/explore/circadian/sleep_timing_summary.dart):
//   summarise(List<NightWindow>) -> SleepTimingSummary
//   clock fields are Durations since local midnight, in [0, 24 h)
//   circular statistics: 23:30 and 00:30 average to 00:00, never 12:00
//   fewer than kMinNightsForSummary (3) valid nights: every clock field null
//   a window whose offset is not after its onset is not a night (not counted)

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/circadian/sleep_timing_summary.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

NightWindow _night(DateTime onset, DateTime offset) =>
    NightWindow(onset: onset, offset: offset);

/// Seconds between two clock values on the circle, shortest way round.
double _circGapMin(Duration a, Duration b) {
  final d = (a - b).inSeconds.abs() % (24 * 3600);
  return (d > 12 * 3600 ? 24 * 3600 - d : d) / 60.0;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('the minimum is three nights', () {
    expect(kMinNightsForSummary, 3);
  });

  test('circular mean across midnight: 23:30, 00:30, 00:00 -> 00:00', () {
    final s = summarise([
      _night(DateTime(2026, 5, 4, 23, 30), DateTime(2026, 5, 5, 7, 30)),
      _night(DateTime(2026, 5, 6, 0, 30), DateTime(2026, 5, 6, 8, 30)),
      _night(DateTime(2026, 5, 7, 0, 0), DateTime(2026, 5, 7, 8, 0)),
    ]);
    expect(s.nights, 3);
    expect(_circGapMin(s.meanOnsetClock!, Duration.zero), lessThan(1.0));
    expect(_circGapMin(s.meanWakeClock!, const Duration(hours: 8)),
        lessThan(1.0));
    // Midpoints 03:30, 04:30, 04:00 -> 04:00. Never the 12 h-off arithmetic mean.
    expect(_circGapMin(s.midSleepClock!, const Duration(hours: 4)),
        lessThan(1.0));
  });

  test('clock fields are normalised into [0, 24 h)', () {
    final s = summarise([
      for (var i = 0; i < 4; i++)
        _night(DateTime(2026, 5, 4 + i, 23, 30), DateTime(2026, 5, 5 + i, 6, 30)),
    ]);
    for (final d in [s.meanOnsetClock!, s.meanWakeClock!, s.midSleepClock!]) {
      expect(d, greaterThanOrEqualTo(Duration.zero));
      expect(d, lessThan(const Duration(hours: 24)));
    }
    expect(_circGapMin(s.meanOnsetClock!, const Duration(hours: 23, minutes: 30)),
        lessThan(1.0));
    expect(_circGapMin(s.meanWakeClock!, const Duration(hours: 6, minutes: 30)),
        lessThan(1.0));
    // 23:30 -> 06:30 is 7 h; the middle is 03:00.
    expect(_circGapMin(s.midSleepClock!, const Duration(hours: 3)),
        lessThan(1.0));
  });

  test('onset spread is the circular SD: identical nights -> ~0', () {
    final s = summarise([
      for (var i = 0; i < 5; i++)
        _night(DateTime(2026, 5, 4 + i, 23, 0), DateTime(2026, 5, 5 + i, 7, 0)),
    ]);
    expect(s.onsetSpread!.inSeconds, lessThan(60));
  });

  test('onset spread, circular SD of 23:30 / 00:30 / 00:00 is ~24.5 min', () {
    // R = (1 + 2 cos 7.5 deg) / 3; SD = sqrt(-2 ln R) rad = 24.51 min of clock.
    final s = summarise([
      _night(DateTime(2026, 5, 4, 23, 30), DateTime(2026, 5, 5, 7, 30)),
      _night(DateTime(2026, 5, 6, 0, 30), DateTime(2026, 5, 6, 8, 30)),
      _night(DateTime(2026, 5, 7, 0, 0), DateTime(2026, 5, 7, 8, 0)),
    ]);
    final minutes = s.onsetSpread!.inSeconds / 60.0;
    expect(minutes, closeTo(24.5, 1.5));
  });

  test('a wider scatter has a larger spread', () {
    SleepTimingSummary withOnsets(List<int> minutesPastMidnight) => summarise([
          for (var i = 0; i < minutesPastMidnight.length; i++)
            _night(
              DateTime(2026, 5, 5 + i).add(Duration(minutes: minutesPastMidnight[i])),
              DateTime(2026, 5, 5 + i, 9, 0),
            ),
        ]);
    final tight = withOnsets([-30, 0, 30]);
    final loose = withOnsets([-120, 0, 120]);
    expect(loose.onsetSpread!, greaterThan(tight.onsetSpread!));
    expect(loose.onsetSpread!.inMinutes, greaterThan(60));
  });

  test('fewer than 3 nights: every clock field is null, nights still counted',
      () {
    final two = summarise([
      _night(DateTime(2026, 5, 4, 23, 0), DateTime(2026, 5, 5, 7, 0)),
      _night(DateTime(2026, 5, 5, 23, 0), DateTime(2026, 5, 6, 7, 0)),
    ]);
    expect(two.nights, 2);
    expect(two.meanOnsetClock, isNull);
    expect(two.meanWakeClock, isNull);
    expect(two.onsetSpread, isNull);
    expect(two.midSleepClock, isNull);

    final none = summarise(const []);
    expect(none.nights, 0);
    expect(none.meanOnsetClock, isNull);
    expect(none.midSleepClock, isNull);
  });

  test('a window that does not end after it starts is not a night', () {
    final s = summarise([
      _night(DateTime(2026, 5, 4, 23, 0), DateTime(2026, 5, 5, 7, 0)),
      _night(DateTime(2026, 5, 5, 23, 0), DateTime(2026, 5, 6, 7, 0)),
      _night(DateTime(2026, 5, 6, 23, 0), DateTime(2026, 5, 6, 23, 0)),
      _night(DateTime(2026, 5, 7, 23, 0), DateTime(2026, 5, 7, 7, 0)),
    ]);
    expect(s.nights, 2);
    expect(s.meanOnsetClock, isNull);
  });

  test('a DST night uses real elapsed time for its midpoint', () {
    // US spring-forward 2026-03-08: 02:00 EST -> 03:00 EDT. 23:00 EST to 07:00
    // EDT is 7 h elapsed, so the midpoint is 3 h 30 after onset = 03:30 EDT.
    // Wall-clock subtraction (23:00 -> 07:00) would put it at 03:00.
    final ny = tz.getLocation('America/New_York');
    final s = summarise([
      _night(tz.TZDateTime(ny, 2026, 3, 5, 23, 0),
          tz.TZDateTime(ny, 2026, 3, 6, 7, 0)),
      _night(tz.TZDateTime(ny, 2026, 3, 6, 23, 0),
          tz.TZDateTime(ny, 2026, 3, 7, 7, 0)),
      _night(tz.TZDateTime(ny, 2026, 3, 7, 23, 0),
          tz.TZDateTime(ny, 2026, 3, 8, 7, 0)),
    ]);
    expect(s.nights, 3);
    expect(_circGapMin(s.meanOnsetClock!, const Duration(hours: 23)),
        lessThan(1.0));
    expect(_circGapMin(s.meanWakeClock!, const Duration(hours: 7)),
        lessThan(1.0));
    // Mid-sleeps 03:00, 03:00, 03:30 -> mean 03:10 (a wall-clock midpoint on
    // the DST night would give 03:00).
    expect(_circGapMin(s.midSleepClock!, const Duration(hours: 3, minutes: 10)),
        lessThan(1.0));
  });
}
