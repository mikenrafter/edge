// A restore carries the old install's alert records, so flagged days that were
// already announced stay announced; flags with no record (an older backup) come
// back as one summary. Real export and import, no hand-built context.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/pulse_alert_delivery.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup/backup_support.dart';

const _flag = 'irregular_rhythm_flag';
const _sentDay = '2026-09-21';
const _summarisedDay = '2026-09-20';
const _newDay = '2026-09-19';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;

  setUpAll(() async => env = await BackupEnv.create('pulse_phase1_restore.db'));
  tearDownAll(() async {
    NotificationCenter.instance.presentSink = original;
    await env.dispose();
  });
  setUp(() {
    shown.clear();
    NotificationIds.instance.resetForTest();
    NotificationCenter.instance.presentSink =
        (e, {bool allowPermissionPrompt = true}) async {
          shown.add(e);
          return true;
        };
  });

  Future<void> oldInstall({required bool withRecords}) async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    await env.seedData();
    final db = await LocalDb.instance;
    for (final day in [_summarisedDay, _newDay]) {
      await db.insert('day_result', {
        'day_id': day, 'algo_version': 100, 'payload_json': '{}',
        'computed_at': 1, 'finalized': 1,
      });
    }
    for (final day in [_sentDay, _summarisedDay, _newDay]) {
      await LocalDb.putMetricSeriesValue(day, _flag, 1);
    }
    if (withRecords) {
      await LocalDb.claimNotifFired('$_sentDay:irregular-pulse');
      await LocalDb.recordPulseAlert([_sentDay],
          state: PulseAlertState.sent, atMs: 1790000000000);
      await LocalDb.recordPulseAlert([_summarisedDay],
          state: PulseAlertState.summary,
          atMs: 1790000100000,
          summaryKey: 'pulse-summary:1:x');
      await LocalDb.recordPulseAlert([_newDay],
          state: PulseAlertState.notSent,
          atMs: 1790000200000,
          reason: PulseAlertReason.off);
    }
  }

  // why: rule 5 across a restore. The new install must not alert for what the
  // old one already did, and must still owe what the old one never delivered.
  // proves: CLAIM(pulse-origin); catches: pulse_alert missing from the restore.
  test('restore keeps delivery records: announced days never re-alert', () async {
    await oldInstall(withRecords: true);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);

    final records = await LocalDb.pulseAlertRecords();
    expect(records[_sentDay]!.state, PulseAlertState.sent);
    expect(records[_sentDay]!.atMs, 1790000000000);
    expect(records[_summarisedDay]!.state, PulseAlertState.summary);
    expect(records[_newDay]!.reason, PulseAlertReason.off);
    expect(await LocalDb.pulseDaysToAlert(), [_newDay],
        reason: 'only the day the old install never delivered is still owed');

    await PulseAlertDelivery.run(individualDays: {_sentDay, _summarisedDay});
    expect(shown, hasLength(1));
    expect(shown.single.dedupeKey, startsWith('pulse-summary:'));
    expect(shown.single.title, contains('1 day'));
    await PulseAlertDelivery.run();
    expect(shown, hasLength(1));
  });

  // why: a backup from before this feature has flags and no records. They are
  // announced once, as a summary, not one by one and not never.
  test('a backup with flags but no records restores to one summary', () async {
    await oldInstall(withRecords: false);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    expect(await LocalDb.pulseDaysToAlert(), [_newDay, _summarisedDay, _sentDay]);
    await PulseAlertDelivery.run();
    expect(shown, hasLength(1));
    expect(shown.single.title, contains('3 days'));
    await PulseAlertDelivery.run();
    expect(shown, hasLength(1));
  });

  // why: R2-DS2 (PERSISTENCE-CHECKLIST, selected-day export). The days travel
  // with their flags, so they must travel with what became of their alerts, or
  // the other phone announces days this one already announced.
  test('a selected-day export carries the alert records of those days', () async {
    await oldInstall(withRecords: true);
    final out = await LocalDb.exportDaysDb({_sentDay, _summarisedDay});
    final db = await databaseFactory.openDatabase(out);
    try {
      final rows = await db.rawQuery('SELECT day, state FROM pulse_alert ORDER BY day');
      expect(rows.map((r) => (r['day'], r['state'])), [
        (_summarisedDay, 'summary'),
        (_sentDay, 'sent'),
      ], reason: 'the two selected days only; the third day is not claimed');
    } finally {
      await db.close();
      await databaseFactory.deleteDatabase(out);
    }
    expect(File(out).existsSync(), isFalse);
  });
}
