// Shared set-up for the round 3 snooze safety tests (Sol's second review,
// alarm-snooze-sol-review2-2026-10-07.md). Real sqflite_ffi database, real
// wake_meta snooze store, real confirmation store; the rig is
// snooze_band_rig.dart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'snooze_band_rig.dart';

const Duration kMin = Duration(minutes: 1);
const Duration kSec = Duration(seconds: 1);

/// The snooze settings JSON with the opt-in switch on (the contract the round 3
/// tests use for the new `enabled` field), plus [over].
SnoozeSettings snoozeOn([Map<String, Object?> over = const {}]) =>
    SnoozeSettings.fromJson({'enabled': true, ...over});

/// The `enabled` field of the settings, read through JSON so a missing field
/// reads as null (and fails an `isFalse`/`isTrue`), not as a compile error.
Object? enabledOf(SnoozeSettings s) => s.toJson()['enabled'];

Future<SnoozeState?> storedState() => const DbSnoozeStore().loadState();
Future<SnoozeWindow?> storedWindow() => const DbSnoozeStore().loadWindow();

String _window(DateTime onset, DateTime? offset) => jsonEncode({
      'value': {
        'onset_ms': onset.millisecondsSinceEpoch,
        if (offset != null) 'offset_ms': offset.millisecondsSinceEpoch,
      },
    });

/// A night block (onset 23:00 the day before, up 07:15, or ending at [upAt])
/// and a confirmed wake stored at [at]. Real stores.
Future<void> lastNightConfirmedAt(DateTime at, {DateTime? upAt}) async {
  final offset = upAt ?? DateTime(2026, 10, 7, 7, 15);
  final onset = upAt == null
      ? DateTime(2026, 10, 6, 23, 0)
      : upAt.subtract(const Duration(hours: 8, minutes: 15));
  await LocalDb.putDayResult(
    dayId: dayLabelOf(offset),
    algoVersion: 1,
    payloadJson: '{}',
    windowJson: _window(onset, offset),
  );
  await LocalDb.putWakeConfirmation(
    dayId: dayLabelOf(offset),
    atSec: secOf(at),
    basis: 'app_opened',
  );
}

/// Registers the usual set-up for a snooze rig suite on database [dbName].
void snoozeSuiteSetup(String dbName) {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, dbName));
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = dbName;
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
    await wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    await SnoozeBandRig.measure();
  });
  setUp(() async {
    await wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    HeadlessSyncGate.resetForTest();
  });
  tearDownAll(wipe);
}
