// F4: movement nudge compensates for the 10-minute throttle window (#830)
// while keeping the fork's ReminderSleepGate suppression.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_stillness_nudge_comp_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
    await const NotificationPrefs(
      movementEnabled: true,
      quietEnabled: false,
    ).save();
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('movement at 09:00 arms for 11:10 so a throttled 09:09 movement never '
      'fires under 2 hours of stillness', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final t0900 = DateTime(2026, 11, 21, 9, 0);
    final due1 = await app.debugRescheduleStillnessNudge(
      t0900.millisecondsSinceEpoch,
    );
    expect(due1, DateTime(2026, 11, 21, 11, 10));

    final t0909 = DateTime(2026, 11, 21, 9, 9);
    final due2 = await app.debugRescheduleStillnessNudge(
      t0909.millisecondsSinceEpoch,
    );
    expect(due2, DateTime(2026, 11, 21, 11, 10));
    expect(
      due2!.difference(t0909),
      greaterThanOrEqualTo(const Duration(hours: 2)),
    );
  });

  test('sleep gate suppresses the compensated deadline when it lands in '
      'expected sleep', () async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      'expected_sleep_schedule_v1',
      jsonEncode(const ExpectedSleepSchedule(
        onsetMinute: 10 * 60,
        wakeMinute: 12 * 60,
      ).toJson()),
    );
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final due = await app.debugRescheduleStillnessNudge(
      DateTime(2026, 11, 21, 9, 0).millisecondsSinceEpoch,
    );
    expect(due, isNull);
  });
}
