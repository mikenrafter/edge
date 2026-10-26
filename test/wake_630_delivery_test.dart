import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/band_buzzer_fakes.dart';
import 'support/wake_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;
  late WakeClock clock;
  late WakeTransport transport;
  final end = DateTime(2026, 10, 25, 7);
  final epoch = end.millisecondsSinceEpoch ~/ 1000;
  const store = DbWakeStateStore();
  const settingsStore = DbWakeSettingsStore();

  Future<void> startApp() async {
    app = AppState(initialize: false);
    transport = WakeTransport(clock);
    app.bandBuzzer = transport.buzzer();
    app.engine.debugInstallFakeLink(onWrite: (_) async => true);
    app.device.connection = 'connected';
    app.device.alarmEpoch = epoch;
    await app.debugReloadAlarmSchedule();
  }
  Future<void> tick() => clock.run(() => app.engine.onKeepAlive!());

  Future<void> seedDetection() async {
    final db = await LocalDb.instance;
    final at = clock.at.millisecondsSinceEpoch ~/ 1000;
    final batch = db.batch();
    // Flat 60 bpm baseline, then a quiet 70 bpm arousal. No rising ENMO.
    for (var i = 0; i < 60; i++) {
      for (final sample in [(at - 600 + i, 60), (at - 60 + i, 70)]) {
        batch.insert('decoded_onehz', {'rec_ts': sample.$1,
          'ts_ms': sample.$1 * 1000, 'counter': i, 'hr': sample.$2,
          'ax': 0.0, 'ay': 0.0, 'az': 1.0});
      }
    }
    await batch.commit(noResult: true);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
    dir = await openWakeDb();
    clock = WakeClock(end.subtract(const Duration(minutes: 30)));
    await LocalDb.setAlarmScheduleDay(weekday: end.weekday - 1,
        hour: 7, minute: 0, enabled: true);
    await settingsStore.save(const WakeSettings(naturalEnabled: true,
        gradualEnabled: true, gradualCadenceSec: 300));
    await startApp();
  });
  tearDown(() async {
    app.dispose();
    BleEngine.resetBandClaimForTest();
    await closeWakeDb(dir);
  });

  test('both modes fire independently, Natural repeats after restart, ack stops both', () => clock.run(() async {
    await seedDetection();
    await tick();
    expect(transport.writes.map((w) => w.kind), ['pulse', 'alarm']);
    expect((await store.load())!['naturalFired'], true);
    expect((await store.load())!['gradualNext'], 1);
    expect(app.naturalWakeBuzzing, true);
    expect(app.activeWakeEpoch, epoch);
    await tick();
    expect(transport.writes, hasLength(2), reason: 'repeat is bounded to 30 seconds');
    app.dispose();
    await LocalDb.close();
    BleEngine.resetBandClaimForTest();
    await startApp();
    clock.at = clock.at.add(const Duration(seconds: 30));
    await tick();
    expect(transport.writes.map((w) => w.kind), ['alarm']);
    clock.at = end.subtract(const Duration(minutes: 25));
    await tick();
    expect(transport.writes.map((w) => w.kind), ['alarm', 'pulse', 'alarm'],
        reason: 'Natural repeats do not suppress the next Gradual step');
    await app.acknowledgeWake(epoch);
    expect(app.activeWakeEpoch, isNull);
    expect((await store.load())!['acknowledged'], true);
    clock.at = end.subtract(const Duration(minutes: 20));
    await tick();
    expect(transport.writes.map((w) => w.kind), ['alarm', 'pulse', 'alarm']);
    expect(app.alarmEpoch, epoch, reason: 'native fallback remains armed');
  }));

  test('a thin detector window allows Gradual only; repeats stop at T', () => clock.run(() async {
    await tick();
    expect(transport.writes.map((w) => w.kind), ['pulse']);
    expect(app.naturalWakeBuzzing, false);
    await store.update(epoch, (run) => run['naturalFired'] = true);
    await app.debugReloadAlarmSchedule();
    clock.at = clock.at.add(const Duration(seconds: 30));
    await tick();
    expect(transport.writes.map((w) => w.kind), ['pulse', 'alarm']);
    clock.at = end;
    await tick();
    expect(transport.writes, hasLength(2));
    expect(app.activeWakeEpoch, isNull);
    expect(app.alarmEpoch, epoch);
  }));

  test('backup import reloads live schedule and global settings', () => clock.run(() async {
    final db = await LocalDb.instance;
    final backup = '${dir.path}/wake-settings.db';
    await db.execute('VACUUM INTO ?', [backup]);
    app.device.connection = 'disconnected';
    await app.setWakeSettings(const WakeSettings());
    await LocalDb.setAlarmScheduleDay(weekday: end.weekday - 1,
        hour: 8, minute: 15, enabled: true);
    await app.debugReloadAlarmSchedule();
    await app.importEdgeBackup(backup);
    expect(app.wakeSettings.naturalEnabled, true);
    expect(app.wakeSettings.gradualEnabled, true);
    final slot = app.alarmSchedule.singleWhere((e) => e.enabled);
    expect((slot.hour, slot.minute), (7, 0));
  }));

  test('Gradual off does not suppress Natural', () => clock.run(() async {
    await settingsStore.save(const WakeSettings(naturalEnabled: true));
    await app.debugReloadAlarmSchedule();
    await seedDetection();
    await tick();
    expect(transport.writes.map((w) => w.kind), ['alarm']);
  }));
}
