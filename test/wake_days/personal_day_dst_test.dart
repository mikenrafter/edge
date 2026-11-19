import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/sleep_ring_model.dart';
import 'process_tz.dart';

void main() {
  final original = Platform.environment['TZ'];
  setUp(() => setProcessTz('America/Denver'));
  tearDown(() => setProcessTz(original));
  // WHY / CLAIM(personal-days): calendar nights follow the wall clock,
  // while the estimate counts real minutes. catches: adding a fixed 24h.
  test('Denver fall-back noon calendar cycle lasts 25 hours', () {
    final days = personalDays(from: DateTime(2026, 10, 31, 12),
      until: DateTime(2026, 11, 1, 12), sleeps: [], mode: PersonalDayMode.calendarOffset);
    expect(days.single.end.difference(days.single.start).inHours, 25);
    expect(days.single.label, '2026-11-01'); // 13h on Sunday, 12h Saturday.
  });
  test('Denver main sleep wake-to-wake survives fall-back', () {
    final days = personalDays(from: DateTime(2026, 10, 31, 8),
      until: DateTime(2026, 11, 1, 8), mode: PersonalDayMode.wakeToWake,
      sleeps: [MainSleep(DateTime(2026, 10, 30, 23), DateTime(2026, 10, 31, 8)),
        MainSleep(DateTime(2026, 10, 31, 23), DateTime(2026, 11, 1, 8))]);
    expect(days.single.end.difference(days.single.start).inHours, 25);
  });
  test('parked estimate fall-back is nine hours, including at 01:00', () {
    final m = sleepRingModel(dayMode: PersonalDayMode.wakeToWake, now: DateTime(2026, 10, 31, 7, 30),
      nextAlarm: DateTime(2026, 11, 1, 7), learnedOnsetMin: 23*60, learnedWakeMin: 8*60);
    expect(m.estimateMin, 9*60);
    expect(sleepRingModel(now: DateTime(2026, 11, 1, 1),
      nextAlarm: DateTime(2026, 11, 1, 7), learnedOnsetMin: 23*60,
      learnedWakeMin: 8*60).estimateMin, 7*60);
  });
  test('alarm past the next learned night is not tonight', () {
    final m = sleepRingModel(dayMode: PersonalDayMode.wakeToWake, now: DateTime(2026, 10, 31, 20),
      nextAlarm: DateTime(2026, 11, 1, 13), learnedOnsetMin: 23*60,
      learnedWakeMin: 8*60);
    expect(m.wakeSource, WakeSource.learned);
    expect(m.estimateMin, 10*60); // 23 MDT to 08 MST.
  });
}
