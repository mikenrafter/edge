// After a wipe and an import the owner has every setting back. These pin the
// gaps the audit found: backup.cadence swept up by a prefix, consent state half
// restored, coach chat sessions left behind, and a coach key lost without a word.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import '../support/fake_alarm_engine.dart';

import 'backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_complete_test.db'));
  tearDownAll(() async => env.dispose());

  Future<void> wipeAll() async {
    await env.wipe();
    for (final f in env.docs.listSync().whereType<File>()) {
      f.deleteSync();
    }
    FlutterSecureStorage.setMockInitialValues({});
  }

  test('the auto-backup cadence the owner chose comes back; device state stays',
      () async {
    await wipeAll();
    await setPrefs({
      'backup.cadence': 'weekly',
      'backup.folder': 'content://x',
      'backup.last_run_ms': 5,
      'backup.last_error': 'boom',
    });
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['backup.cadence'], 'weekly');
    expect(now.containsKey('backup.folder'), isFalse);
    expect(now.containsKey('backup.last_run_ms'), isFalse);
    expect(now.containsKey('backup.last_error'), isFalse);
  });

  test('consent is asked again as a whole: no half-restored consent state',
      () async {
    await wipeAll();
    await setPrefs({
      'consent_telemetry': true,
      'consent_health_data': true,
      'consent_chosen': true,
    });
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now.keys.where((k) => k.startsWith('consent_')), isEmpty);
  });

  test('coach chat sessions travel and come back byte-exact, only if absent',
      () async {
    await wipeAll();
    File(p.join(env.docs.path, 'coach_idx_anon.json')).writeAsStringSync('[1]');
    File(p.join(env.docs.path, 'coach_s_anon_17.json')).writeAsStringSync('{"a":1}');
    File(p.join(env.docs.path, 'unrelated.txt')).writeAsStringSync('x');
    await env.seedData();
    final path = await LocalDb.exportCopy();
    final files = await exportedFiles(path);
    expect(files!.keys.toSet(), {'coach_idx_anon.json', 'coach_s_anon_17.json'});

    await wipeAll();
    File(p.join(env.docs.path, 'coach_idx_anon.json')).writeAsStringSync('[9]');
    await LocalDb.importFromDbFile(path);
    expect(File(p.join(env.docs.path, 'coach_s_anon_17.json')).readAsStringSync(),
        '{"a":1}');
    expect(File(p.join(env.docs.path, 'coach_idx_anon.json')).readAsStringSync(),
        '[9]', reason: 'what the device has is kept');
    expect(File(p.join(env.docs.path, 'unrelated.txt')).existsSync(), isFalse);
  });

  test('a coach key that cannot travel is reported for re-entry, never hidden',
      () async {
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-SECRET'});
    await setPrefs({'coach_api_key_present': true, 'coach_model': 'm'});
    await env.seedData();
    final path = await LocalDb.exportCopy();
    expectNoSecretIn(path, ['sk-SECRET']);

    await wipeAll(); // the new phone has no keychain payload
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['coach_model'], 'm');
    expect(now.containsKey('coach_api_key_present'), isFalse,
        reason: 'the marker would claim a key this phone does not hold');
    final s = await lastImportSummary();
    expect(s, isNotNull);
    expect(s!.needsReentry, ['coach_api_key']);
  });

  test('no re-entry is reported when the key is already on this phone or never set',
      () async {
    await wipeAll();
    await setPrefs({'coach_model': 'm'});
    await env.seedData();
    final never = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(never);
    expect((await lastImportSummary())!.needsReentry, isEmpty);

    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-1'});
    await setPrefs({'coach_api_key_present': true});
    await env.seedData();
    final had = await LocalDb.exportCopy();
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-1'});
    await LocalDb.importFromDbFile(had);
    expect((await lastImportSummary())!.needsReentry, isEmpty);
  });

  group('Cancel-all survives an import', () {
    late AppState app;

    // A schedule exported, then cancelled on an install that has data.
    Future<String> exportThenCancel() async {
      await wipeAll();
      await env.seedData();
      await LocalDb.setAlarmScheduleDay(
          weekday: 2, hour: 7, minute: 15, enabled: true);
      final path = await LocalDb.exportCopy();
      app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      await app.disableAlarm();
      expect(await LocalDb.alarmScheduleRows(), isEmpty);
      return path;
    }

    test('an import does not bring a cancelled schedule back', () async {
      final path = await exportThenCancel();
      await LocalDb.importFromDbFile(path);
      expect(await LocalDb.alarmScheduleRows(), isEmpty);
    });

    test('configuring a weekday after Cancel-all lets a later import fill '
        'absent slots again', () async {
      final path = await exportThenCancel();
      await app.setScheduleDay(weekday: 4, hour: 6, minute: 0, enabled: true);
      await LocalDb.importFromDbFile(path);
      final byDay = {
        for (final r in await LocalDb.alarmScheduleRows()) r['weekday']: r,
      };
      expect(byDay.keys.toSet(), {2, 4});
      expect(byDay[4]!['hour'], 6, reason: 'the local row still wins');
    });

    test('a fresh install still restores the schedule', () async {
      await wipeAll();
      await LocalDb.setAlarmScheduleDay(
          weekday: 2, hour: 7, minute: 15, enabled: true);
      final path = await LocalDb.exportCopy();
      await wipeAll();
      await setPrefs({'alarm_schedule_cleared': true});
      await LocalDb.importFromDbFile(path);
      expect(await LocalDb.alarmScheduleRows(), hasLength(1));
    });

    test('the cancel marker is device state: it is not exported', () async {
      await wipeAll();
      await setPrefs({'alarm_schedule_cleared': true});
      final out = await LocalDb.exportCopy();
      expect((await exportedPrefs(out))?.keys ?? <String>[],
          isNot(contains('alarm_schedule_cleared')));
    });
  });
}
