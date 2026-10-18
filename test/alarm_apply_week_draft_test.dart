// The draft's "apply this day to the whole week". Pure: no widgets, no band.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

List<AlarmScheduleEntry> _week() => fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(
    weekday: 1,
    hour: 7,
    minute: 15,
    enabled: true,
    naturalWindowMinutes: 45,
    gradualWindowMinutes: 30,
    gradualPattern: GradualPattern.steady,
    gradualCadenceSec: 300,
  ),
  AlarmScheduleEntry(weekday: 4, hour: 5, minute: 0, enabled: true),
]);

void main() {
  test('copies the day to every day, keeping each weekday', () {
    final d = AlarmDraft(_week());
    d.applyToWeek(1);
    for (var i = 0; i < 7; i++) {
      final e = d.entry(i);
      expect(e.weekday, i, reason: 'a day stays its own weekday');
      expect([e.enabled, e.hour, e.minute], [true, 7, 15]);
      expect(e.naturalWindowMinutes, 45);
      expect(e.gradualWindowMinutes, 30);
      expect(e.gradualPattern, GradualPattern.steady);
      expect(e.gradualCadenceSec, 300);
    }
    expect(d.dirty, isTrue);
    expect(d.canSave, isTrue);
    expect(d.saved, _week(), reason: 'the saved copy never moves');
  });

  test('an off day applies as off', () {
    final d = AlarmDraft(_week());
    d.applyToWeek(0);
    expect(d.entries.every((e) => !e.enabled), isTrue);
  });

  test('notifies once, however many days change', () {
    final d = AlarmDraft(_week());
    var n = 0;
    d.addListener(() => n++);
    d.applyToWeek(1);
    expect(n, 1);
  });

  test('weekMatches: false while any day differs, true once applied', () {
    final d = AlarmDraft(_week());
    expect(d.weekMatches(1), isFalse);
    d.applyToWeek(1);
    expect(d.weekMatches(1), isTrue);
    expect(d.weekMatches(5), isTrue, reason: 'every day is the same now');
    d.setTime(6, 8, 0);
    expect(d.weekMatches(1), isFalse);
  });

  test('applying twice is idempotent: no second notification', () {
    final d = AlarmDraft(_week());
    d.applyToWeek(1);
    var n = 0;
    d.addListener(() => n++);
    d.applyToWeek(1);
    expect(n, 0);
  });

  test('applying then editing back to saved is clean again', () {
    final d = AlarmDraft(_week());
    d.applyToWeek(1);
    d.discard();
    expect(d.dirty, isFalse);
  });

  test('a bad weekday throws', () {
    final d = AlarmDraft(_week());
    expect(() => d.applyToWeek(7), throwsArgumentError);
    expect(() => d.weekMatches(-1), throwsArgumentError);
  });
}
