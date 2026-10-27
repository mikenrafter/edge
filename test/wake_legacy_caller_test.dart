import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'support/fake_alarm_engine.dart';

class Band extends FakeAlarmEngine {
  int buzzes = 0;
  @override
  Future<void> runAlarm() async {
    buzzes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wake = DateTime(2026, 10, 26, 7);
  final now = DateTime(2026, 10, 26, 6, 40);
  late AppState app;
  late Band band;
  late Database db;
  late Directory databaseDir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    databaseDir = await Directory.systemTemp.createTemp('wake_legacy_');
    LocalDb.dbName = '${databaseDir.path}/legacy.db';
    await databaseFactory.deleteDatabase(LocalDb.dbName);
    db = await LocalDb.instance;
    band = Band()
      ..debugInstallFakeLink(onWrite: (_) async => true, listening: true);
    band.state.generation = 'gen4';
    app = AppState.forTesting(engine: band)..debugWakeClock = () => now;
    await app.sleepOperations.saveSchedule(
      const ExpectedSleepSchedule(
        onsetMinute: 22 * 60,
        wakeMinute: 7 * 60,
      ).toJson(),
    );
    await app.loadExpectedSleepSchedule();
    await LocalDb.setAlarmScheduleRows([
      for (var d = 0; d < 7; d++)
        AlarmScheduleEntry(
          weekday: d,
          hour: 7,
          minute: 0,
          enabled: true,
          smartWindowMinutes: 60,
        ).toRow(),
    ]);
    await app.debugLoadAlarmSchedule();
    // The preceding completed main sleep crosses midnight; its label alone
    // cannot identify its relation to the current occurrence.
    await db.insert('day_result', {
      'day_id': '2026-10-25',
      'algo_version': 117,
      'computed_at': 0,
      'finalized': 1,
      'partial': 0,
      'skipped': 0,
      'window_json': jsonEncode({
        'value': {
          'onset_ms': DateTime(2026, 10, 24, 22).millisecondsSinceEpoch,
          'offset_ms': DateTime(2026, 10, 25, 7).millisecondsSinceEpoch,
        },
      }),
      'payload_json': jsonEncode({
        'scalars': {'hr_min_night': 50},
      }),
    });
    final batch = db.batch();
    for (var s = 0; s < 300; s++) {
      final ts = now.millisecondsSinceEpoch ~/ 1000 - 300 + s;
      batch.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': s,
        'hr': 54,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
      });
    }
    await batch.commit(noResult: true);
  });
  tearDown(() async {
    app.dispose();
    await LocalDb.close();
    await databaseDir.delete(recursive: true);
  });
  test(
    'actual AppState legacy caller uses historical fallback and deduplicates delivery',
    () async {
      await app.debugCheckLegacySmartWake(wake);
      expect(band.buzzes, 1);
      await app.debugCheckLegacySmartWake(wake);
      expect(band.buzzes, 1);
      expect(band.sets, isEmpty);
      expect(band.disables, 0);
    },
  );
  test(
    'actual caller loads journal, invalidates on edit and retains native arm',
    () async {
      await LocalDb.putJournalMetrics('2026-10-25', {
        'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 21 * 60),
      });
      await app.debugCheckLegacySmartWake(wake);
      expect(band.buzzes, 0, reason: '+4 HR cannot meet alcohol +6');
      await LocalDb.putJournalMetrics('2026-10-25', {});
      await app.debugCheckLegacySmartWake(wake);
      expect(
        band.buzzes,
        1,
        reason: 'same occurrence must see the cleared journal',
      );
      expect(band.sets, isEmpty);
      expect(band.disables, 0);
    },
  );
  test(
    'saved morning schedule adjusts alcohol and caffeine timing through production',
    () async {
      final morningWake = DateTime(2026, 10, 26, 16);
      final morningNow = DateTime(2026, 10, 26, 15, 40);
      app.debugWakeClock = () => morningNow;
      await app.sleepOperations.saveSchedule(
        const ExpectedSleepSchedule(
          onsetMinute: 8 * 60,
          wakeMinute: 16 * 60,
        ).toJson(),
      );
      await app.loadExpectedSleepSchedule();
      // Shift all measurements together by nine hours without changing the
      // amount or quality of evidence.
      await db.rawUpdate(
        'UPDATE decoded_onehz SET rec_ts = rec_ts + 9*3600, ts_ms = ts_ms + 9*3600000',
      );
      await LocalDb.putJournalMetrics('2026-10-26', {
        'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 6 * 60),
      });
      await app.debugCheckLegacySmartWake(morningWake);
      expect(band.buzzes, 0);
      await LocalDb.putJournalMetrics('2026-10-26', {
        'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 2 * 60),
      });
      await app.debugCheckLegacySmartWake(morningWake);
      expect(band.buzzes, 0, reason: 'morning caffeine uses the six-hour lead');
      await LocalDb.putJournalMetrics('2026-10-26', {});
      await app.debugCheckLegacySmartWake(morningWake);
      expect(band.buzzes, 1);
    },
  );
  test(
    'null accelerometry in production abstains and preserves native arm',
    () async {
      await db.update('decoded_onehz', {'ax': null, 'ay': null, 'az': null});
      await app.debugCheckLegacySmartWake(wake);
      expect(band.buzzes, 0);
      expect(band.sets, isEmpty);
      expect(band.disables, 0);
    },
  );
}
