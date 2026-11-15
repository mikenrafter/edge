// WHY: a release may be rediscovered every day and from two isolates; it must
// cause at most one phone alert, respect quiet hours and never prompt headless.
// Proves CLAIM(update-notification-claim), CLAIM(update-release-page).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:openstrap_edge/sync/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  final center = NotificationCenter.instance;
  final event = NotificationEvent(dedupeKey: 'release:official:123',
    category: NotifCategory.updates, title: 'Update available', body: 'Official v0.11.4',
    date: '2026-11-15', route: 'https://github.com/OpenStrap/edge/releases/tag/v0.11.4');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('update-notif-');
    store = UpdateStore(await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'));
    await store.initialize();
    center.updateStore = () async => store;
    await store.setEnabled(true);
    await const NotificationPrefs(quietEnabled: false).save();
  });
  tearDown(() async {
    center.updateStore = UpdateStore.open;
    await store.db.close();
    await directory.delete(recursive: true);
  });

  // catches: a check-then-record race or date-prefixed release identity.
  test('concurrent emit and next-day rediscovery present once without prompts', () async {
    var shows = 0;
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
      expect(allowPermissionPrompt, isFalse);
      shows++;
      return true;
    };
    final results = await Future.wait(List.generate(8, (_) => center.emit(event)));
    expect(results.where((v) => v), hasLength(1));
    expect(await center.emit(NotificationEvent(dedupeKey: event.dedupeKey,
      category: event.category, title: event.title, body: event.body,
      date: '2026-11-16', route: event.route)), isFalse);
    expect(shows, 1);
  });

  // catches: new-category bypass of quiet hours, permission requests or disabled consent.
  test('quiet and opted-out releases cannot reach the phone', () async {
    var shows = 0;
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async { shows++; return true; };
    final minute = DateTime.now().hour * 60 + DateTime.now().minute;
    await NotificationPrefs(quietStartMin: minute, quietEndMin: (minute + 2) % 1440).save();
    expect(await center.emit(event), isFalse);
    await const NotificationPrefs(quietEnabled: false).save();
    await store.setEnabled(false);
    expect(await center.emit(event), isFalse);
    expect(shows, 0);
  });

  // catches: unsafe payload reaching launcher through a notification.
  test('untrusted update notification route is refused before presentation', () async {
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async => fail('unsafe route');
    expect(await center.emit(NotificationEvent(dedupeKey: event.dedupeKey,
      category: event.category, title: event.title, body: event.body,
      date: event.date, route: 'https://evil.test/a.apk')), isFalse);
  });

  // catches: category mute swallowing the explicitly opted-in update channel.
  test('update class is quiet-hours aware and independent of health/device switches', () {
    const prefs = NotificationPrefs(healthEnabled: false, deviceEnabled: false);
    expect(prefs.shouldFireOs(event, 12 * 60), isTrue);
    expect(prefs.shouldFireOs(event, 23 * 60), isFalse);
  });

  // catches: WorkManager Wi-Fi/connected constraint in place of UNMETERED.
  test('periodic registration requires unmetered with a daily interval', () {
    expect(updateTaskFrequency, const Duration(days: 1));
    expect(updateTaskNetworkType.name, 'unmetered');
  });
}
