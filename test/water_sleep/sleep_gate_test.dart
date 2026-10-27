import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../backup/backup_support.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';
import 'package:openstrap_edge/state/control_operations.dart';

DateTime at(int hour, [int minute = 0]) => DateTime(2026, 10, 26, hour, minute);
const nocturnal = ReminderSleepGate(
  schedule: ExpectedSleepSchedule(onsetMinute: 480, wakeMinute: 960),
);
const quietOff = NotificationPrefs(waterEnabled: true, quietEnabled: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv dbEnv;
  setUpAll(() async {
    dbEnv = await BackupEnv.create('reminder_sleep_context.db');
  });
  tearDownAll(() => dbEnv.dispose());
  setUp(() => dbEnv.wipe());
  test(
    'validation runs in UTC',
    () => expect(Platform.environment['TZ'], 'UTC'),
  );
  test('quiet hours explain suppression at start and release at end', () {
    const gate = ReminderSleepGate();
    const prefs = NotificationPrefs();
    expect(gate.reasonAt(prefs, at(21, 59)), isNull);
    expect(gate.reasonAt(prefs, at(22)), ReminderSuppression.quietHours);
    expect(gate.reasonAt(prefs, at(6, 59)), ReminderSuppression.quietHours);
    expect(gate.reasonAt(prefs, at(7)), isNull);
  });
  test('nocturnal schedule suppresses 08 inclusive to 16 exclusive', () {
    expect(nocturnal.reasonAt(quietOff, at(7, 59)), isNull);
    expect(
      nocturnal.reasonAt(quietOff, at(8)),
      ReminderSuppression.sleepSchedule,
    );
    expect(
      nocturnal.reasonAt(quietOff, at(15, 59)),
      ReminderSuppression.sleepSchedule,
    );
    expect(nocturnal.reasonAt(quietOff, at(16)), isNull);
    expect(nocturnal.reasonAt(quietOff, at(2)), isNull);
  });
  test('sleep schedule across midnight checks both calendar halves', () {
    const gate = ReminderSleepGate(
      schedule: ExpectedSleepSchedule(onsetMinute: 1380, wakeMinute: 420),
    );
    expect(gate.reasonAt(quietOff, at(22, 59)), isNull);
    expect(gate.reasonAt(quietOff, at(23)), ReminderSuppression.sleepSchedule);
    expect(gate.reasonAt(quietOff, at(2)), ReminderSuppression.sleepSchedule);
    expect(gate.reasonAt(quietOff, at(7)), isNull);
  });
  test('closed detected nap suppresses only its actual interval', () {
    final gate = ReminderSleepGate(
      periods: [ReminderSleepPeriod(at(18), at(19))],
    );
    expect(gate.reasonAt(quietOff, at(17, 59)), isNull);
    expect(gate.reasonAt(quietOff, at(18)), ReminderSuppression.asleep);
    expect(gate.reasonAt(quietOff, at(18, 59)), ReminderSuppression.asleep);
    expect(gate.reasonAt(quietOff, at(19)), isNull);
  });
  test('open detected sleep blocks until an observed end is supplied', () {
    final gate = ReminderSleepGate(periods: [ReminderSleepPeriod(at(17))]);
    expect(gate.reasonAt(quietOff, at(16, 59)), isNull);
    expect(gate.reasonAt(quietOff, at(20)), ReminderSuppression.asleep);
  });
  test('overlap explanation precedence is quiet then schedule then asleep', () {
    final gate = ReminderSleepGate(
      schedule: nocturnal.schedule,
      periods: [ReminderSleepPeriod(at(8), at(17))],
    );
    const prefs = NotificationPrefs(quietStartMin: 600, quietEndMin: 660);
    expect(gate.reasonAt(prefs, at(10)), ReminderSuppression.quietHours);
    expect(gate.reasonAt(prefs, at(12)), ReminderSuppression.sleepSchedule);
    expect(gate.reasonAt(prefs, at(16)), ReminderSuppression.asleep);
  });
  test(
    'saved nocturnal schedule is consumed by production context load',
    () async {
      SharedPreferences.setMockInitialValues({
        'expected_sleep_schedule_v1': '{"onsetMinute":480,"wakeMinute":960}',
      });
      final gate = await ReminderSleepGate.load(now: at(12));
      expect(
        gate.reasonAt(quietOff, at(12)),
        ReminderSuppression.sleepSchedule,
      );
    },
  );
  test('due assumed slots exclude daytime sleep with default quiet hours', () {
    final prefs = NotificationPrefs(
      waterEnabled: true,
      waterAssumeDrank: true,
      waterAssumeSinceMs: at(0).millisecondsSinceEpoch,
    );
    expect(AssumedWater.dueSlots(prefs, now: at(21), sleep: nocturnal), [
      at(7),
      at(17),
      at(19),
      at(21),
    ]);
  });
  test(
    'same-day quiet hours are respected by actual assumed slot generator',
    () {
      final prefs = NotificationPrefs(
        waterEnabled: true,
        waterAssumeDrank: true,
        quietStartMin: 600,
        quietEndMin: 960,
        waterAssumeSinceMs: at(0).millisecondsSinceEpoch,
      );
      final slots = AssumedWater.dueSlots(
        prefs,
        now: at(20),
        sleep: const ReminderSleepGate(),
      );
      expect(slots, [at(8), at(16), at(18), at(20)]);
    },
  );
  test('water schedule includes awake night when quiet hours are disabled', () {
    final slots = NotificationCenter.waterSlotMinutes(
      quietOff,
      sleep: nocturnal,
    );
    expect(
      slots,
      contains(120),
      reason: '02:00 is awake, not a daytime fallback',
    );
    expect(slots.where((m) => m >= 480 && m < 960), isEmpty);
  });
  test(
    'water slots keep default quiet hours independently of daytime sleep',
    () {
      const prefs = NotificationPrefs(waterEnabled: true);
      expect(NotificationCenter.waterSlotMinutes(prefs, sleep: nocturnal), [
        420,
        1020,
        1140,
        1260,
      ]);
    },
  );
  test('movement reminder checks target time against sleep schedule', () {
    expect(
      NotificationCenter.stillnessNudgeAt(quietOff, at(7), sleep: nocturnal),
      isNull,
      reason: '07:00 movement would arm a 09:00 interruption',
    );
    expect(
      NotificationCenter.stillnessNudgeAt(quietOff, at(16), sleep: nocturnal),
      at(18),
    );
  });
  test('unknown sleep does not invent a sleep window', () {
    expect(const ReminderSleepGate().reasonAt(quietOff, at(12)), isNull);
  });
  test('wind-down nudge refuses a target inside expected daytime sleep', () {
    expect(
      NotificationCenter.windDownSlot(
        const NotificationPrefs(windDownEnabled: true, quietEnabled: false),
        840,
        sleep: nocturnal,
      ),
      isNull,
    );
  });
  test('check-in nudge refuses a target inside expected evening sleep', () {
    const gate = ReminderSleepGate(
      schedule: ExpectedSleepSchedule(onsetMinute: 1080, wakeMinute: 1380),
    );
    expect(
      NotificationCenter.checkInSlot(
        const NotificationPrefs(checkInEnabled: true, quietEnabled: false),
        null,
        doneToday: false,
        now: at(17),
        sleep: gate,
      ),
      isNull,
    );
  });
}
