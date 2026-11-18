import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('alert_policy_settings.db'));
  tearDownAll(() => env.dispose());
  setUp(() async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
  });

  // WHY / CLAIM(alert-settings-travel): restore real serialized settings into
  // a separate installation, preserving choices and retiring the old override.
  test('fallback travels through export and restore while override stays local', () async {
    await const NotificationPrefs(fallbackDestination: AlertDestination.band).save();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('notif_critical_override', true);
    final legacyBlob = jsonDecode(sp.getString(NotificationPrefs.storageKey)!) as Map;
    (legacyBlob['preferences'] as Map)['criticalOverridesQuiet'] = true;
    await sp.setString(NotificationPrefs.storageKey, jsonEncode(legacyBlob));
    final path = await LocalDb.exportCopy();
    final exported = (await exportedPrefs(path))!;
    expect(exported['notif_fallback_destination'], ('string', 'band'));
    expect(exported.containsKey('notif_critical_override'), isFalse);
    final blob = jsonDecode(exported[NotificationPrefs.storageKey]!.$2) as Map;
    expect((blob['preferences'] as Map).containsKey('criticalOverridesQuiet'), isFalse);
    await env.wipe();
    await restoreBackupExtras(path, freshInstall: true);
    expect((await NotificationPrefs.load()).fallbackDestination, AlertDestination.band);
    await const NotificationPrefs().copyWith(fallbackDestination: AlertDestination.phone).save();
    await restoreBackupExtras(path, freshInstall: false);
    expect((await NotificationPrefs.load()).fallbackDestination, AlertDestination.phone);
  });

  // WHY / CLAIM(alert-settings-parse): malformed stored/imported values cannot
  // crash a settings read or become an unsupported destination.
  test('missing blank unknown and wrong typed fallback use phone', () async {
    for (final value in [null, '', 'watch', 42, true]) {
      SharedPreferences.setMockInitialValues({
        'notif_fallback_destination': ?value,
      });
      expect((await NotificationPrefs.load()).fallbackDestination, AlertDestination.phone,
        reason: '$value');
    }
  });

  test('invalid imported fallback is reported and refused', () async {
    final path = await LocalDb.exportCopy();
    for (final (type, value) in [('string', ''), ('string', 'watch'), ('int', '42')]) {
      final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
      await copy.insert(kBackupPrefsTable, {'key': 'notif_fallback_destination',
        'type': type, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
      await copy.close();
      final result = await restoreBackupExtras(path, freshInstall: true);
      expect(result.refusedPrefs, contains('notif_fallback_destination'));
      expect((await NotificationPrefs.load()).fallbackDestination, AlertDestination.phone);
    }
  });
  // WHY / CLAIM(alert-critical-retired): old serialized settings remain
  // readable after real import without restoring their quiet-hours bypass.
  test('imported legacy override true cannot bypass quiet hours', () async {
    final legacy = const NotificationPrefs().toJson();
    (legacy['preferences'] as Map)['criticalOverridesQuiet'] = true;
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(singleInstance: false));
    await copy.insert(kBackupPrefsTable, {'key': NotificationPrefs.storageKey,
      'type': 'string', 'value': jsonEncode(legacy)},
      conflictAlgorithm: ConflictAlgorithm.replace);
    await copy.insert(kBackupPrefsTable, {'key': 'notif_critical_override',
      'type': 'bool', 'value': 'true'}, conflictAlgorithm: ConflictAlgorithm.replace);
    await copy.close();
    await env.wipe();
    await restoreBackupExtras(path, freshInstall: true);
    final prefs = await NotificationPrefs.load();
    expect(prefs.criticalOverridesQuiet, isTrue);
    final event = NotificationEvent(dedupeKey: 'legacy', category: NotifCategory.health,
      priority: NotifPriority.critical, title: 'Health', body: '', date: '2026-11-17');
    expect(prefs.shouldFireOs(event, 23 * 60), isFalse);
  });
}
