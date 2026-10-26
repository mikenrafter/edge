// Screenshots of the Wake section and the Home acknowledgement card, for review.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/screens/wake_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/band_buzzer_fakes.dart';
import 'support/bundled_fonts.dart';
import 'support/wake_db.dart';

const _boundary = ValueKey('wake-shot');
final _now = DateTime(2026, 10, 25, 22);
final _alarm = DateTime(2026, 10, 26, 7);

Widget _shell(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'), theme: buildTheme(Brightness.light),
    home: RepaintBoundary(key: _boundary, child: child));

void main() {
  late Directory dir;
  setUpAll(loadFonts);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
    dir = await openWakeDb();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await closeWakeDb(dir);
  });

  final cases = {
    'off': const WakeSettings(),
    'natural': const WakeSettings(naturalEnabled: true),
    'both': const WakeSettings(naturalEnabled: true, gradualEnabled: true),
  };
  for (final e in cases.entries) {
    testWidgets('alarm screen wake ${e.key}', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(412, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(_shell(AlarmScreenView(
        now: _now, armedAt: _alarm, state: AlarmArmState.confirmed,
        connected: true,
        schedule: fillDefaultAlarmSchedule([
          for (var d = 0; d < 5; d++)
            AlarmScheduleEntry(weekday: d, hour: 7, minute: 0, enabled: true),
        ]),
        wakeSettings: e.value, onSetWakeSettings: (_) async {})));
      await t.pumpAndSettle();
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/wake_630_alarm_${e.key}.png'));
    });
  }

  for (final natural in [false, true]) {
    testWidgets('home wake card ${natural ? 'natural' : 'gradual'}', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(412, 200);
      addTearDown(t.view.reset);
      final app = AppState(initialize: false);
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
        if (natural) {
          await const DbWakeStateStore().update(epoch, (run) => run['naturalFired'] = true);
        }
        await app.debugReloadAlarmSchedule();
      });
      try {
        await clock.run(() async {
          await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
              child: _shell(const Scaffold(body: Padding(
                  padding: EdgeInsets.all(S.x4),
                  child: Align(alignment: Alignment.topCenter, child: WakeCard()))))));
          await t.pumpAndSettle();
          await expectLater(find.byKey(_boundary), matchesGoldenFile(
              'goldens/wake_630_home_${natural ? 'natural' : 'gradual'}.png'));
        });
      } finally {
        await t.pumpWidget(const SizedBox());
        app.dispose();
      }
    });
  }
}
