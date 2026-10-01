import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> pump(WidgetTester t, Widget widget) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  await t.pumpWidget(
    MaterialApp(theme: buildTheme(Brightness.light), home: widget),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'relay enable does not move capability summary or reveal unrelated groups',
    (t) async {
      addTearDown(t.view.reset);
      await pump(t, const BandNotificationsView(enabled: false, granted: true));
      final before = t.getTopLeft(find.text('One buzz per notification'));
      await pump(t, const BandNotificationsView(enabled: true, granted: true));
      expect(
        t.getTopLeft(find.text('One buzz per notification')),
        before,
        reason: 'details expand only through an explicit accordion',
      );
    },
  );
  testWidgets(
    'Android relay exposes three independent channels and channel-wide policies',
    (t) async {
      addTearDown(t.view.reset);
      await pump(t, const BandNotificationsView(enabled: true, granted: true));
      for (final label in [
        'App notifications',
        'Alarms & timers',
        'Incoming calls',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('iOS'), findsNothing);
    },
  );
  testWidgets('Alerts has persistent groups and all four destination options', (
    t,
  ) async {
    addTearDown(t.view.reset);
    await pump(t, const NotificationSettingsView(relaySupported: true));
    for (final label in [
      'Alarms & Wake',
      'Health',
      'Activity',
      'Reminders',
      'Device',
      'Android Relay',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // The picker may be in an accordion, but destinations must be selectable
    // from a single common widget, rather than unrelated boolean switches.
    expect(find.text('Phone'), findsWidgets);
    expect(find.text('Band'), findsWidgets);
    expect(find.text('Phone + Band'), findsWidgets);
  });
  testWidgets('Sleep empty state still offers Recalculate this night', (
    t,
  ) async {
    addTearDown(t.view.reset);
    await pump(t, SleepDetail(data: SleepData(day: '2026-09-30')));
    expect(find.text('Recalculate this night'), findsOneWidget);
  });
  test(
    'native listener wiring carries metadata and cannot send private content',
    () {
      final dart = File(
        'lib/notify/notification_relay.dart',
      ).readAsStringSync();
      expect(
        dart,
        isNot(contains("package:notification_listener_service/")),
        reason: 'the third-party content-bearing bridge must be replaced',
      );
      final nativeFiles = Directory('android/app/src/main')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt') || f.path.endsWith('.java'));
      final native = nativeFiles.map((f) => f.readAsStringSync()).join('\n');
      expect(native, contains('NotificationListenerService'));
      expect(native, contains('matchesInterruptionFilter'));
      expect(native, contains('onNotificationRemoved'));
      expect(native, isNot(contains('EXTRA_TEXT')));
      expect(native, isNot(contains('EXTRA_TITLE')));
      expect(
        native,
        isNot(contains('setInterruptionFilter(')),
        reason: 'band override cannot change global DND',
      );
    },
  );
  test('sleep union range is used by actual candidate loader', () {
    final source = File(
      'lib/compute/derivation_engine.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Future<SleepSessionCandidate> _sleepCandidateForDay',
    );
    final end = source.indexOf('final searchSub', start);
    final loader = source.substring(start, end);
    expect(
      loader,
      contains('overrideOnsetSec:'),
      reason: 'the tested union helper must feed production loading',
    );
    expect(loader, contains('overrideOffsetSec:'));
  });
  test('haptic producers use common dispatcher policy', () {
    for (final path in [
      'lib/notify/water_buzzer.dart',
      'lib/notify/med_buzzer.dart',
      'lib/notify/notification_relay.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains('AlertDispatcher'),
        reason: '$path must deliver through policy, not directly buzz',
      );
    }
  });
  test('persistent Sync now reaches Home and primary band detail', () {
    final home = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
    final devices = File('lib/ui2/profile/devices.dart').readAsStringSync();
    expect(home, contains('SyncPresentationState'));
    expect(devices, contains('SyncPresentationState'));
  });
}
