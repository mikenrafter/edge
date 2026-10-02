// After an explicit acknowledgement cancels tonight's native alarm, the next
// connect or sync must not quietly re-arm it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';

void main() {
  final schedule = fillDefaultAlarmSchedule([
    for (var w = 0; w < 7; w++)
      AlarmScheduleEntry(weekday: w, hour: 7, minute: 0),
  ]);
  final t = DateTime(2026, 10, 5, 7, 0); // Monday
  final now = DateTime(2026, 10, 5, 6, 40);

  test('without an acknowledgement the search starts now', () {
    expect(armSearchFrom(now, null), now);
    expect(nextAlarmOccurrence(schedule, armSearchFrom(now, null)), t);
  });

  test('an acknowledged occurrence still ahead is skipped, not re-armed', () {
    final from = armSearchFrom(now, t.millisecondsSinceEpoch ~/ 1000);
    expect(nextAlarmOccurrence(schedule, from), DateTime(2026, 10, 6, 7, 0));
  });

  test('an old acknowledgement no longer matters', () {
    final old = DateTime(2026, 10, 3, 7, 0).millisecondsSinceEpoch ~/ 1000;
    expect(armSearchFrom(now, old), now);
  });
}
