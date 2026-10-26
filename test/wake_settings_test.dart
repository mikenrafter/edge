import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('window validation accepts off and each 15-minute step through 120', () {
    for (final minutes in [0, 15, 30, 45, 60, 75, 90, 105, 120]) {
      expect(isValidWakeWindow(minutes), isTrue, reason: '$minutes minutes');
    }
    for (final minutes in [-15, -1, 1, 14, 16, 119, 121, 135]) {
      expect(isValidWakeWindow(minutes), isFalse, reason: '$minutes minutes');
    }
  });

  test('cadence validation accepts whole minutes from 1 through 15 only', () {
    for (var seconds = 60; seconds <= 900; seconds += 60) {
      expect(isValidGradualCadence(seconds), isTrue, reason: '$seconds seconds');
    }
    for (final seconds in [-60, 0, 59, 61, 899, 901, 960]) {
      expect(isValidGradualCadence(seconds), isFalse, reason: '$seconds seconds');
    }
  });

  test('global settings default off, retain both modes and round trip JSON', () {
    const defaults = WakeSettings();
    expect(defaults.naturalEnabled, false);
    expect(defaults.gradualEnabled, false);
    final settings = defaults.copyWith(naturalEnabled: true,
        naturalWindowMinutes: 90, gradualEnabled: true, gradualWindowMinutes: 60,
        gradualCadenceSec: 420, gradualPattern: GradualPattern.steady);
    expect(settings.toJson(), {
      'naturalEnabled': true, 'naturalWindowMinutes': 90, 'gradualEnabled': true,
      'gradualWindowMinutes': 60, 'gradualCadenceSec': 420, 'gradualPattern': 'steady',
    });
    final read = WakeSettings.fromJson(settings.toJson());
    expect(read.copyWith(gradualEnabled: false).toJson(), {
      'naturalEnabled': true, 'naturalWindowMinutes': 90, 'gradualEnabled': false,
      'gradualWindowMinutes': 60, 'gradualCadenceSec': 420, 'gradualPattern': 'steady',
    });
  });

  test('global settings reject invalid windows even when modes are off', () {
    for (final minutes in [0, -15, 14, 16, 121, 135]) {
      expect(() => WakeSettings().copyWith(naturalWindowMinutes: minutes).validate(),
          throwsArgumentError);
      expect(() => WakeSettings().copyWith(gradualWindowMinutes: minutes).validate(),
          throwsArgumentError);
    }
    for (final seconds in [0, 59, 61, 901]) {
      expect(() => WakeSettings().copyWith(gradualCadenceSec: seconds).validate(),
          throwsArgumentError);
    }
    expect(() => WakeSettings.fromJson({'gradualPattern': 'invalid'}), throwsArgumentError);
  });

  final alarm = DateTime.utc(2026, 10, 25, 7);
  List<GradualStep> steps({int window = 30, int cadence = 300,
      GradualPattern pattern = GradualPattern.ramp}) => GradualWakeSchedule.steps(
      wakeAt: alarm, windowMinutes: window, cadenceSec: cadence, pattern: pattern);

  test('ramp retains fork formula, six steps give 1 1 2 3 3 4 pulses', () {
    final result = steps();
    expect(result.map((s) => s.index), [0, 1, 2, 3, 4, 5]);
    expect(result.map((s) => s.at), [
      DateTime.utc(2026, 10, 25, 6, 30), DateTime.utc(2026, 10, 25, 6, 35),
      DateTime.utc(2026, 10, 25, 6, 40), DateTime.utc(2026, 10, 25, 6, 45),
      DateTime.utc(2026, 10, 25, 6, 50), DateTime.utc(2026, 10, 25, 6, 55),
    ]);
    // 1 + floor(i*4/6), i=0..5. The fork never reaches five here.
    expect(result.map((s) => s.pulses), [1, 1, 2, 3, 3, 4]);
  });

  test('steady and non-dividing cadence keep the native alarm moment exclusive', () {
    final result = steps(window: 15, cadence: 420, pattern: GradualPattern.steady);
    expect(result.map((s) => s.at), [
      DateTime.utc(2026, 10, 25, 6, 45), DateTime.utc(2026, 10, 25, 6, 52),
      DateTime.utc(2026, 10, 25, 6, 59),
    ]);
    expect(result.map((s) => s.pulses), [1, 1, 1]);
    expect(steps(window: 0), isEmpty);
  });

  test('invalid schedule parameters are rejected instead of silently normalized', () {
    expect(() => steps(window: 16), throwsArgumentError);
    expect(() => steps(window: 135), throwsArgumentError);
    expect(() => steps(cadence: 0), throwsArgumentError);
    expect(() => steps(cadence: 61), throwsArgumentError);
    expect(() => steps(cadence: 960), throwsArgumentError);
  });

  test('America/Denver spring-forward uses 120 elapsed minutes before local T', () {
    final denver = tz.getLocation('America/Denver');
    final t = tz.TZDateTime(denver, 2026, 3, 8, 3, 30);
    expect(t.toUtc(), DateTime.utc(2026, 3, 8, 9, 30));
    final result = GradualWakeSchedule.steps(wakeAt: t, windowMinutes: 120,
        cadenceSec: 900, pattern: GradualPattern.ramp);
    expect(result.map((s) => s.at.toUtc()), [
      DateTime.utc(2026, 3, 8, 7, 30), DateTime.utc(2026, 3, 8, 7, 45),
      DateTime.utc(2026, 3, 8, 8), DateTime.utc(2026, 3, 8, 8, 15),
      DateTime.utc(2026, 3, 8, 8, 30), DateTime.utc(2026, 3, 8, 8, 45),
      DateTime.utc(2026, 3, 8, 9), DateTime.utc(2026, 3, 8, 9, 15),
    ]);
    expect(result.map((s) => tz.TZDateTime.from(s.at, denver).hour),
        [0, 0, 1, 1, 1, 1, 3, 3]);
  });

  test('America/Denver fall-back distinguishes both repeated 01:00 hours', () {
    final denver = tz.getLocation('America/Denver');
    final t = tz.TZDateTime(denver, 2026, 11, 1, 2, 30);
    expect(t.toUtc(), DateTime.utc(2026, 11, 1, 9, 30));
    final result = GradualWakeSchedule.steps(wakeAt: t, windowMinutes: 120,
        cadenceSec: 900, pattern: GradualPattern.steady);
    expect(result.map((s) => s.at.toUtc()), [
      DateTime.utc(2026, 11, 1, 7, 30), DateTime.utc(2026, 11, 1, 7, 45),
      DateTime.utc(2026, 11, 1, 8), DateTime.utc(2026, 11, 1, 8, 15),
      DateTime.utc(2026, 11, 1, 8, 30), DateTime.utc(2026, 11, 1, 8, 45),
      DateTime.utc(2026, 11, 1, 9), DateTime.utc(2026, 11, 1, 9, 15),
    ]);
    expect(result.map((s) => tz.TZDateTime.from(s.at, denver).hour),
        [1, 1, 1, 1, 1, 1, 2, 2]);
  });
}
