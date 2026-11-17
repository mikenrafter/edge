// WHY: main's delivery and cancel/save ordering fixes must run through the
// fork's real shared alarm owner, not an unused helper left by the merge.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'support/fake_alarm_engine.dart';

class _Band extends FakeAlarmEngine {
  bool delivered = true;
  Future<void> Function()? beforeDisable;
  @override
  Future<bool> disableAlarm({int? id}) async {
    disables++;
    await beforeDisable?.call();
    return delivered;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'alarm_cancel_safety_merge.db';
    await databaseFactory.deleteDatabase(p.join(
        await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });
  tearDownAll(LocalDb.close);
  late _Band band;
  late AppState app;
  late SharedPreferences prefs;
  final when = DateTime(2030, 1, 2, 7);
  final epoch = when.millisecondsSinceEpoch ~/ 1000;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    band = _Band();
    app = AppState.forTesting(engine: band);
    app.debugSetAlarmGraceMs(60000);
    await LocalDb.clearAlarmSchedule();
    await LocalDb.setAlarmScheduleDay(
        weekday: 2, hour: 7, minute: 0, enabled: true);
    await app.debugLoadAlarmSchedule();
    await app.debugOnArmed(when, epoch);
  });
  tearDown(() => app.dispose());

  // # catches: ignoring a false DISABLE_ALARM delivery and clearing local state.
  // proves: CLAIM(alarm-cancel-delivery).
  test('failed cancel keeps both persisted arm and schedule', () async {
    band.delivered = false;
    await expectLater(app.disableAlarm(), throwsException);
    expect(app.alarmEpoch, epoch);
    expect(prefs.getInt('alarm_epoch'), epoch);
    expect(prefs.getBool('alarm_schedule_cleared'), isNot(true));
    expect((await LocalDb.alarmScheduleRows()).single['hour'], 7);
  });

  // # catches: a save committing during cancel and being deleted afterwards.
  // proves: CLAIM(alarm-cancel-save-order).
  test('a day save waits for cancel, then remains saved', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    band.beforeDisable = () async { started.complete(); await release.future; };
    final cancel = app.disableAlarm();
    await started.future;
    final save = app.setScheduleDay(weekday: 2, hour: 9, enabled: true);
    // Drain ordinary async work without advancing an alarm's wall clock.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final during = await LocalDb.alarmScheduleRows();
    release.complete();
    await cancel;
    await save;
    expect(during.single['hour'], 7, reason: 'save waits behind the cancel');
    expect((await LocalDb.alarmScheduleRows()).single['hour'], 9);
    expect(prefs.getBool('alarm_schedule_cleared'), isNot(true));
  });
}
