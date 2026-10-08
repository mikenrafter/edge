// Round 3 (Sol, alarm-snooze-sol-review2-2026-10-07.md): the settings side. RED.
//
//  A  Snooze is OPT-IN, default OFF (an owner-safety decision): the settings
//     carry an `enabled` field that is false unless the wearer switched it on;
//     the alarm screen shows a "Snooze" switch, off by default, and the four
//     other rows are disabled-not-hidden while it is off
//  H  Android: the backstop is exact when the alarm permission allows it; the
//     manifest declares the permission, and when exact timing is unavailable
//     the snooze settings say so in one line
//
// Contract used where the production API is new: the settings JSON field
// `enabled` (read through toJson/fromJson); the switch is a SwitchRow titled
// "Snooze" on the alarm screen.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_alarm_engine.dart';
import '../support/settings_sections.dart' show isDimmed;
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart' show enabledOf, snoozeOn;

const _rows = [
  'Double taps to dismiss',
  'Dismiss window',
  'Snooze for',
  'Stop escalating after',
];
const _exactNote = 'Exact timing needs the alarm permission';
const _dbName = 'openstrap_snooze_r3_settings_ui_test.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, _dbName));
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
    await wipe();
  });
  setUp(() async {
    await wipe();
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(wipe);

  group('A the setting', () {
    test('defaults to OFF, and anything unreadable is OFF', () {
      expect(enabledOf(const SnoozeSettings()), isFalse);
      expect(enabledOf(SnoozeSettings.fromJson(null)), isFalse);
      expect(enabledOf(SnoozeSettings.fromJson(<String, Object?>{})), isFalse);
      expect(
          enabledOf(SnoozeSettings.fromJson({'requiredTaps': 3, 'minutes': 9})),
          isFalse,
          reason: 'settings written before the switch existed stay off');
      expect(enabledOf(SnoozeSettings.fromJson({'enabled': 'yes'})), isFalse);
      expect(enabledOf(SnoozeSettings.fromJson({'enabled': 1})), isFalse);
    });

    test('on only when the stored value is true; round trips; kept by every '
        'copy', () {
      final on = snoozeOn();
      expect(enabledOf(on), isTrue);
      expect(enabledOf(SnoozeSettings.fromJson(on.toJson())), isTrue);
      expect(enabledOf(on.copyWith(minutes: 12)), isTrue);
      expect(enabledOf(on.copyWith(requiredTaps: 9)), isTrue);
      expect(on.toJson()['enabled'], isTrue);
    });

    test('on and off are different settings (equality sees the switch)', () {
      expect(snoozeOn(), isNot(equals(const SnoozeSettings())));
      expect(snoozeOn().hashCode, isNot(const SnoozeSettings().hashCode));
    });

    test('the wake_meta store keeps it', () async {
      const store = DbSnoozeStore();
      expect(enabledOf(await store.loadSettings()), isFalse);
      await store.saveSettings(snoozeOn({'minutes': 7}));
      final back = await store.loadSettings();
      expect(enabledOf(back), isTrue);
      expect(back.minutes, 7);
      await store.saveSettings(back.copyWith(minutes: 8));
      expect(enabledOf(await store.loadSettings()), isTrue);
    });
  });

  group('A the alarm screen', () {
    late NotificationSpy n;
    setUp(() => n = NotificationSpy());
    tearDown(() => n.uninstall());

    Future<AppState> pumpScreen(WidgetTester t, String generation,
        {bool on = false}) async {
      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.engine.state.generation = generation;
      // A warm database: a first write inside the test's fake-async zone leaves
      // a pending timer behind.
      await t.runAsync(() => LocalDb.instance);
      if (on) {
        await t.runAsync(() => app.setSnoozeSettings(snoozeOn()));
      }
      t.view.physicalSize = const Size(1170, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const AlarmScreen(),
        ),
      ));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      return app;
    }

    Finder snoozeRow() => find.byWidgetPredicate(
        (w) => w is SwitchRow && w.title == 'Snooze',
        description: 'the "Snooze" switch row');

    testWidgets('a "Snooze" switch is there, OFF by default; the four rows '
        'are present, dimmed and inert (disabled, not hidden)', (t) async {
      final app = await pumpScreen(t, 'gen5');
      expect(snoozeRow(), findsOneWidget);
      expect(t.widget<SwitchRow>(snoozeRow()).value, isFalse);
      for (final label in _rows) {
        expect(find.text(label), findsOneWidget,
            reason: '"$label" must be disabled, not hidden');
        expect(isDimmed(t, find.text(label)), isTrue, reason: label);
        await t.tap(find.text(label), warnIfMissed: false);
        await t.pumpAndSettle();
        expect(find.byType(SimpleDialog), findsNothing,
            reason: 'a disabled row opens nothing ($label)');
      }
      expect(enabledOf(app.snoozeSettings), isFalse);
    });

    testWidgets('switching it on enables the rows and is stored; off again '
        'dims them', (t) async {
      final app = await pumpScreen(t, 'gen5');
      final toggle =
          find.descendant(of: snoozeRow(), matching: find.byType(Switch));
      await t.tap(toggle);
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pumpAndSettle();
      expect(enabledOf(app.snoozeSettings), isTrue);
      expect(t.widget<SwitchRow>(snoozeRow()).value, isTrue);
      for (final label in _rows) {
        expect(isDimmed(t, find.text(label)), isFalse, reason: label);
      }
      await t.tap(find.text('Snooze for'));
      await t.pumpAndSettle();
      await t.tap(find.text('10 min').last);
      await t.pumpAndSettle();
      expect(app.snoozeSettings.minutes, 10);
      expect(enabledOf(app.snoozeSettings), isTrue,
          reason: 'a choice keeps the switch');

      await t.tap(toggle);
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pumpAndSettle();
      expect(enabledOf(app.snoozeSettings), isFalse);
      expect(isDimmed(t, find.text('Snooze for')), isTrue);
    });

    testWidgets('Gen4: the switch is there but inert, with the rows', (t) async {
      final app = await pumpScreen(t, 'gen4');
      expect(snoozeRow(), findsOneWidget);
      final sw = t.widget<Switch>(
          find.descendant(of: snoozeRow(), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull, reason: 'a band that cannot drive a snooze');
      expect(enabledOf(app.snoozeSettings), isFalse);
    });

    testWidgets('H: exact timing unavailable: one line says so, in the snooze '
        'settings', (t) async {
      n
        ..canExact = false
        ..install();
      try {
        await pumpScreen(t, 'gen5', on: true);
        expect(find.text(_exactNote), findsOneWidget);
      } finally {
        n.uninstall(); // before the framework's platform-override check
      }
    });

    testWidgets('H: exact timing available: no such line', (t) async {
      n
        ..canExact = true
        ..install();
      try {
        await pumpScreen(t, 'gen5', on: true);
        expect(find.text(_exactNote), findsNothing);
      } finally {
        n.uninstall();
      }
    });
  });

  group('H the manifest', () {
    test('declares the exact-alarm permission (an alarm-clock app qualifies '
        'for USE_EXACT_ALARM; SCHEDULE_EXACT_ALARM is the fallback)', () {
      final xml =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final has = xml.contains('android.permission.USE_EXACT_ALARM') ||
          xml.contains('android.permission.SCHEDULE_EXACT_ALARM');
      expect(has, isTrue,
          reason: 'without it exactAllowWhileIdle throws on Android 12+ and '
              'the backstop stays inexact');
    });
  });
}
