// Settings model, the four configurations, the timeline, and the Gradual
// schedule. Pure: no DB, no BLE.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

bool get _denver => Platform.environment['TZ'] == 'America/Denver';

void main() {
  group('window validation', () {
    test('only 0 and 15..120 in 15-minute steps are valid', () {
      final valid = [for (var m = 0; m <= 120; m++) if (isValidWakeWindow(m)) m];
      expect(valid, [0, 15, 30, 45, 60, 75, 90, 105, 120]);
      expect(isValidWakeWindow(-15), isFalse);
      expect(isValidWakeWindow(135), isFalse);
    });

    test('normalize rounds to the nearest step, clamps, and keeps a '
        'positive value positive', () {
      expect(normalizeWakeWindow(0), 0);
      expect(normalizeWakeWindow(-5), 0);
      expect(normalizeWakeWindow(5), 15, reason: 'a user who had a window keeps one');
      expect(normalizeWakeWindow(20), 15);
      expect(normalizeWakeWindow(23), 30);
      expect(normalizeWakeWindow(45), 45);
      expect(normalizeWakeWindow(500), 120);
    });
  });

  group('the four configurations', () {
    test('neither / natural / gradual / both', () {
      expect(wakeConfigurationOf(naturalMinutes: 0, gradualMinutes: 0),
          WakeConfiguration.neither);
      expect(wakeConfigurationOf(naturalMinutes: 45, gradualMinutes: 0),
          WakeConfiguration.naturalOnly);
      expect(wakeConfigurationOf(naturalMinutes: 0, gradualMinutes: 30),
          WakeConfiguration.gradualOnly);
      expect(wakeConfigurationOf(naturalMinutes: 45, gradualMinutes: 30),
          WakeConfiguration.both);
    });

    test('a new schedule entry enables neither feature', () {
      final e = AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0);
      expect(e.naturalWindowMinutes, 0);
      expect(e.gradualWindowMinutes, 0);
      expect(e.gradualPattern, GradualPattern.ramp);
      expect(e.gradualCadenceSec, kGradualCadenceDefaultSec);
    });

    test('entries round-trip through a storage row, absent columns read as off',
        () {
      final e = AlarmScheduleEntry.fromRow({
        'weekday': 2,
        'hour': 6,
        'minute': 30,
        'enabled': 1,
        'smart_window_minutes': 30,
        'natural_window_minutes': 45,
        'gradual_window_minutes': 15,
        'gradual_pattern': 'steady',
        'gradual_cadence_sec': 120,
      });
      expect(e.naturalWindowMinutes, 45);
      expect(e.gradualWindowMinutes, 15);
      expect(e.gradualPattern, GradualPattern.steady);
      expect(e.gradualCadenceSec, 120);
      final legacy = AlarmScheduleEntry.fromRow(
          {'weekday': 1, 'hour': 7, 'minute': 0, 'enabled': 1});
      expect(legacy.naturalWindowMinutes, 0);
      expect(legacy.gradualWindowMinutes, 0);
    });

    test('the collection window follows Natural, or the legacy window while '
        'the upgrade explanation is pending', () {
      final e = AlarmScheduleEntry(
          weekday: 0,
          hour: 7,
          minute: 0,
          smartWindowMinutes: 30,
          naturalWindowMinutes: 90);
      expect(collectionWindowMinutes(e, WakeUpgradeState.acknowledged), 90);
      expect(collectionWindowMinutes(e, WakeUpgradeState.none), 90);
      expect(collectionWindowMinutes(e, WakeUpgradeState.pending), 30);
    });
  });

  group('timeline', () {
    test('every Natural window: starts exactly N minutes before T and '
        'collection leads it by warm-up plus margin', () {
      final t = DateTime(2026, 10, 5, 7, 0);
      for (var n = 15; n <= 120; n += 15) {
        final tl = WakeTimeline.compute(
            wakeAt: t, naturalMinutes: n, gradualMinutes: 0);
        expect(tl.naturalStart, t.subtract(Duration(minutes: n)));
        expect(tl.collectionStart,
            t.subtract(Duration(minutes: n + kNaturalWarmupMinutes + kNaturalCollectionMarginMinutes)));
        expect(naturalCollectionLead(n).inMinutes,
            n + kNaturalWarmupMinutes + kNaturalCollectionMarginMinutes);
        expect(tl.gradualStart, isNull);
      }
    });

    test('the fixed native alarm is always a timeline part, band-native, '
        'at T, in all four configurations', () {
      final t = DateTime(2026, 10, 5, 7, 0);
      for (final (n, g) in [(0, 0), (60, 0), (0, 30), (60, 30)]) {
        final tl = WakeTimeline.compute(
            wakeAt: t, naturalMinutes: n, gradualMinutes: g);
        final fallback = tl.parts.singleWhere((p) => p.id == 'fallback');
        expect(fallback.at, t);
        expect(fallback.bandNative, isTrue);
        expect(fallback.requiresPhone, isFalse);
        for (final p in tl.parts.where((p) => p.id != 'fallback')) {
          expect(p.requiresPhone, isTrue, reason: '${p.id} needs a live link');
          expect(p.bandNative, isFalse);
        }
        expect(tl.parts.map((p) => p.id).contains('natural'), n > 0);
        expect(tl.parts.map((p) => p.id).contains('gradual'), g > 0);
        expect(tl.parts.map((p) => p.id).contains('collection'), n > 0);
      }
    });

    test('the two windows are independent: Gradual start is not borrowed '
        'from Natural', () {
      final t = DateTime(2026, 10, 5, 7, 0);
      final tl = WakeTimeline.compute(
          wakeAt: t, naturalMinutes: 90, gradualMinutes: 15);
      expect(tl.naturalStart, t.subtract(const Duration(minutes: 90)));
      expect(tl.gradualStart, t.subtract(const Duration(minutes: 15)));
    });

    test('DST: the window is N elapsed minutes before T, not N wall-clock '
        'minutes', () {
      // 03:30 on the spring-forward day and 02:30 (second pass) on the
      // fall-back day both have a transition inside a 120-minute window.
      for (final t in [
        DateTime(2026, 3, 8, 3, 30),
        DateTime(2026, 11, 1, 2, 30),
      ]) {
        final tl = WakeTimeline.compute(
            wakeAt: t, naturalMinutes: 120, gradualMinutes: 60);
        expect(t.difference(tl.naturalStart!).inMinutes, 120);
        expect(t.difference(tl.gradualStart!).inMinutes, 60);
        expect(tl.naturalStart!.toUtc(),
            t.toUtc().subtract(const Duration(minutes: 120)));
      }
      if (_denver) {
        final spring = WakeTimeline.compute(
            wakeAt: DateTime(2026, 3, 8, 3, 30),
            naturalMinutes: 120,
            gradualMinutes: 0);
        expect(spring.naturalStart!.hour, 0,
            reason: 'two elapsed hours across the lost hour reads 3h earlier '
                'on the wall clock');
      }
    });

    test('T comes from the LOCAL schedule: 06:30 stays 06:30 on both DST days',
        () {
      final schedule = fillDefaultAlarmSchedule([
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(
              weekday: w, hour: 6, minute: 30, naturalWindowMinutes: 60),
      ]);
      for (final from in [DateTime(2026, 3, 7, 22), DateTime(2026, 10, 31, 22)]) {
        final t = nextAlarmOccurrence(schedule, from)!;
        expect(t.hour, 6);
        expect(t.minute, 30);
        final tl = WakeTimeline.compute(
            wakeAt: t, naturalMinutes: 60, gradualMinutes: 0);
        expect(t.difference(tl.naturalStart!).inMinutes, 60);
      }
    });
  });

  group('Gradual schedule', () {
    test('steps are cadence apart, begin at T-G, and all fall before T', () {
      final t = DateTime(2026, 10, 5, 7, 0);
      for (final g in [15, 30, 60, 120]) {
        for (final cadence in [60, 180, 300]) {
          final steps = GradualWakeSchedule.steps(
              wakeAt: t,
              windowMinutes: g,
              cadenceSec: cadence,
              pattern: GradualPattern.steady);
          expect(steps, isNotEmpty);
          expect(steps.first.at, t.subtract(Duration(minutes: g)));
          expect(steps.length, (g * 60 / cadence).ceil());
          for (var i = 0; i < steps.length; i++) {
            expect(steps[i].index, i);
            expect(steps[i].at.isBefore(t), isTrue);
            if (i > 0) {
              expect(steps[i].at.difference(steps[i - 1].at).inSeconds, cadence);
            }
          }
        }
      }
    });

    test('ramp escalates from one buzz up to a cap; steady is always one', () {
      final t = DateTime(2026, 10, 5, 7, 0);
      final ramp = GradualWakeSchedule.steps(
          wakeAt: t,
          windowMinutes: 30,
          cadenceSec: 60,
          pattern: GradualPattern.ramp);
      final counts = [for (final s in ramp) s.sequence.length];
      expect(counts.first, 1);
      expect(counts.last, greaterThan(1));
      expect(counts.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(5));
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], greaterThanOrEqualTo(counts[i - 1]));
      }
      final steady = GradualWakeSchedule.steps(
          wakeAt: t,
          windowMinutes: 30,
          cadenceSec: 60,
          pattern: GradualPattern.steady);
      expect(steady.every((s) => s.sequence.length == 1), isTrue);
    });

    test('a zero window has no steps', () {
      expect(
          GradualWakeSchedule.steps(
              wakeAt: DateTime(2026, 10, 5, 7),
              windowMinutes: 0,
              cadenceSec: 60,
              pattern: GradualPattern.ramp),
          isEmpty);
    });
  });
}
