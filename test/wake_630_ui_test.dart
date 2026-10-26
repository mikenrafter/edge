import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/screens/wake_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/band_buzzer_fakes.dart';
import 'support/wake_db.dart';

class _App extends AppState {
  _App() : super(initialize: false);
  Future<void>? acknowledgement;
  @override
  Future<void> acknowledgeWake(int epoch) =>
      acknowledgement = super.acknowledgeWake(epoch);
}

Widget _shell(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'), theme: buildTheme(Brightness.light), home: child);

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
    dir = await openWakeDb();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await closeWakeDb(dir);
  });

  testWidgets('one Wake section has two independent toggles and separate controls', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 2000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    var settings = const WakeSettings();
    await t.pumpWidget(_shell(StatefulBuilder(builder: (c, update) =>
      AlarmScreenView(connected: true, wakeSettings: settings,
        onSetWakeSettings: (value) async => update(() => settings = value)))));
    await t.pumpAndSettle();
    expect(find.text('Wake'), findsOneWidget);
    expect(find.text('Natural window'), findsNothing);
    await t.tap(find.text('Natural wake'));
    await t.pumpAndSettle();
    expect(settings.naturalEnabled, true);
    expect(find.text('Natural window'), findsOneWidget);
    await t.tap(find.text('Gradual wake'));
    await t.pumpAndSettle();
    expect(settings.naturalEnabled, true);
    expect(settings.gradualEnabled, true);
    expect(find.text('Gradual window'), findsOneWidget);
    expect(find.text('Cadence'), findsOneWidget);
    expect(find.text('Pattern'), findsOneWidget);
    await t.tap(find.text('Natural wake'));
    await t.pumpAndSettle();
    expect(settings.naturalEnabled, false);
    expect(settings.gradualEnabled, true);
  });

  testWidgets('Home card gives Natural precedence and I\'m up stops both', (t) async {
    final app = _App();
    final end = DateTime(2026, 10, 25, 7);
    final epoch = end.millisecondsSinceEpoch ~/ 1000;
    final clock = WakeClock(end.subtract(const Duration(minutes: 20)));
    app.bandBuzzer = WakeTransport(clock).buzzer();
    app.device.alarmEpoch = epoch;
    await t.runAsync(() async {
      await LocalDb.setAlarmScheduleDay(weekday: end.weekday - 1,
          hour: 7, minute: 0, enabled: true);
      await const DbWakeSettingsStore().save(const WakeSettings(
          naturalEnabled: true, gradualEnabled: true));
      await app.debugReloadAlarmSchedule();
    });
    try {
      await clock.run(() async {
        await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
            child: _shell(const Scaffold(body: WakeCard()))));
        await t.pumpAndSettle();
        expect(find.text('Gradual wake is buzzing'), findsOneWidget);
      });
      await t.runAsync(() async {
        await const DbWakeStateStore().update(epoch, (run) => run['naturalFired'] = true);
        await app.debugReloadAlarmSchedule();
      });
      await clock.run(() async {
        await t.pump(const Duration(seconds: 30));
        expect(find.text('Natural wake is buzzing'), findsOneWidget);
        expect(find.text('Gradual wake is buzzing'), findsNothing);
        await t.runAsync(() async {
          await t.tap(find.text("I'm up"));
          expect(app.acknowledgement, isNotNull);
          await app.acknowledgement!;
        });
        await t.pump();
        expect(find.byKey(const ValueKey('wake-card')), findsNothing);
        final run = await t.runAsync(() => const DbWakeStateStore().load());
        expect(run!['acknowledged'], true);
      });
    } finally {
      await t.pumpWidget(const SizedBox());
      app.dispose();
    }
  });
}
