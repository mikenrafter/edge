// SnoozeSettings (n, dismiss window, snooze minutes, cap): defaults, clamps,
// JSON, and the wake_meta-backed store. RED: the model and DbSnoozeStore are
// stubs that throw.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _dbName = 'openstrap_snooze_settings_test.db';

Future<void> _wipe() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, _dbName));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
  });
  setUp(_wipe);
  tearDownAll(_wipe);

  group('defaults and ranges', () {
    test('2 double taps, a 4000 ms window (its own, not the gesture timing), '
        '5 minutes, cap 6', () {
      const s = SnoozeSettings();
      expect(s.requiredTaps, 2);
      expect(s.windowMs, 4000);
      expect(s.minutes, 5);
      expect(s.cap, 6);
      expect(s.window, const Duration(milliseconds: 4000));
      expect(s.snoozeFor, const Duration(minutes: 5));
    });

    test('the documented ranges', () {
      expect([kSnoozeTapsMin, kSnoozeTapsMax], [1, 5]);
      expect([kSnoozeMinutesMin, kSnoozeMinutesMax], [1, 30]);
      expect([kSnoozeWindowMsMin, kSnoozeWindowMsMax], [1000, 15000]);
      expect([kSnoozeCapMin, kSnoozeCapMax], [1, 20]);
    });
  });

  group('clamps', () {
    test('clamped() pulls every field into range', () {
      final low = SnoozeSettings.clamped(
          requiredTaps: 0, windowMs: 10, minutes: 0, cap: 0);
      expect([low.requiredTaps, low.windowMs, low.minutes, low.cap],
          [1, 1000, 1, 1]);
      final high = SnoozeSettings.clamped(
          requiredTaps: 99, windowMs: 999999, minutes: 99, cap: 99);
      expect([high.requiredTaps, high.windowMs, high.minutes, high.cap],
          [5, 15000, 30, 20]);
    });

    test('in-range values are kept exactly', () {
      final s = SnoozeSettings.clamped(
          requiredTaps: 3, windowMs: 6000, minutes: 12, cap: 4);
      expect([s.requiredTaps, s.windowMs, s.minutes, s.cap], [3, 6000, 12, 4]);
    });

    test('copyWith clamps and leaves the rest', () {
      final s = const SnoozeSettings().copyWith(requiredTaps: 9, minutes: 0);
      expect(s.requiredTaps, 5);
      expect(s.minutes, 1);
      expect(s.windowMs, 4000);
      expect(s.cap, 6);
    });
  });

  group('json', () {
    test('round trips', () {
      final s = SnoozeSettings.clamped(
          requiredTaps: 4, windowMs: 7000, minutes: 9, cap: 3);
      expect(SnoozeSettings.fromJson(s.toJson()), s);
    });

    test('fromJson clamps what is stored out of range', () {
      final s = SnoozeSettings.fromJson(
          {'requiredTaps': 50, 'windowMs': 1, 'minutes': 500, 'cap': -2});
      expect([s.requiredTaps, s.windowMs, s.minutes, s.cap], [5, 1000, 30, 1]);
    });

    test('fromJson never throws: junk is the default of each field', () {
      for (final junk in [null, 'x', 7, <Object?>[], {'requiredTaps': 'two'}]) {
        expect(SnoozeSettings.fromJson(junk), const SnoozeSettings(),
            reason: '$junk');
      }
      final partial = SnoozeSettings.fromJson({'minutes': 10});
      expect(partial.minutes, 10);
      expect(partial.requiredTaps, 2);
    });
  });

  group('DbSnoozeStore (wake_meta)', () {
    const store = DbSnoozeStore();

    test('nothing stored: the defaults and no pending snooze', () async {
      expect(await store.loadSettings(), const SnoozeSettings());
      expect(await store.loadState(), isNull);
    });

    test('settings persist, clamped, across a new store instance', () async {
      await store.saveSettings(const SnoozeSettings(
          requiredTaps: 9, windowMs: 6000, minutes: 12, cap: 3));
      final back = await const DbSnoozeStore().loadSettings();
      expect(back.requiredTaps, 5, reason: 'clamped on the way in or out');
      expect([back.windowMs, back.minutes, back.cap], [6000, 12, 3]);
      expect(await LocalDb.wakeMetaGet(kSnoozeSettingsKey), isNotNull);
    });

    test('a pending snooze persists and clears', () async {
      final st = SnoozeState(count: 3, reAlarmAt: DateTime(2026, 10, 7, 6, 15));
      await store.saveState(st);
      expect(await const DbSnoozeStore().loadState(), st);
      expect(await LocalDb.wakeMetaGet(kSnoozeStateKey), isNotNull);
      await store.saveState(null);
      expect(await const DbSnoozeStore().loadState(), isNull);
    });

    test('unreadable stored values read as defaults / no snooze, never throw',
        () async {
      await LocalDb.wakeMetaSet(kSnoozeSettingsKey, '{not json');
      await LocalDb.wakeMetaSet(kSnoozeStateKey, 'garbage');
      expect(await store.loadSettings(), const SnoozeSettings());
      expect(await store.loadState(), isNull);
      await LocalDb.wakeMetaSet(kSnoozeStateKey, '{"count":0,"reAlarmAt":"x"}');
      expect(await store.loadState(), isNull);
    });

    test('SnoozeState json round trips and keeps the exact instant', () {
      final st = SnoozeState(
          count: 2, reAlarmAt: DateTime.fromMillisecondsSinceEpoch(1791000123456));
      expect(SnoozeState.fromJson(st.toJson()), st);
    });
  });
}
