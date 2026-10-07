// F6 (Sol, 2026-10-07): the snooze settings are offered on every band, but only
// a band that reports HOW the alarm was stopped can drive a snooze. Event 100's
// cause is undecoded on Gen4 (the pinned protocol keeps it numeric), so a Gen4
// wearer would set "2 double taps to dismiss" and nothing would ever happen.
//
// The repo's disable-not-hide rule (test/settings_disable_not_hide_test.dart):
// the rows stay, dimmed and inert, with the reason. Driven through the real
// AlarmScreen over a real AppState, the way the capability scope feeds it.
//
//   gen4: the four rows are present, dimmed, tapping them opens nothing and
//         changes nothing, and the screen says "Snooze needs a band that
//         reports how the alarm was stopped (WHOOP 5/MG)"
//   gen5: the rows work and carry no such note (control)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_alarm_engine.dart';
import '../support/settings_sections.dart' show isDimmed;

const _rows = [
  'Double taps to dismiss',
  'Dismiss window',
  'Snooze for',
  'Stop escalating after',
];
const _note = 'Snooze needs a band that reports how the alarm was stopped '
    '(WHOOP 5/MG)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_snooze_capability_ui_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpScreen(WidgetTester t, String generation) async {
    final app = AppState.forTesting(engine: FakeAlarmEngine());
    addTearDown(app.dispose);
    app.engine.state.generation = generation;
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
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pump();
    return app;
  }

  testWidgets('Gen4: the rows are present, dimmed and inert, with the reason',
      (t) async {
    final app = await pumpScreen(t, 'gen4');
    for (final label in _rows) {
      expect(find.text(label), findsOneWidget,
          reason: '"$label" must be disabled, not hidden');
      expect(isDimmed(t, find.text(label)), isTrue, reason: label);
    }
    expect(find.text(_note), findsOneWidget);
    for (final label in _rows) {
      await t.tap(find.text(label), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing,
          reason: 'a disabled row opens nothing ($label)');
    }
    expect(app.snoozeSettings, const SnoozeSettings());
  });

  testWidgets('Gen5: the rows work and say nothing about a missing capability',
      (t) async {
    final app = await pumpScreen(t, 'gen5');
    for (final label in _rows) {
      expect(find.text(label), findsOneWidget, reason: label);
      expect(isDimmed(t, find.text(label)), isFalse, reason: label);
    }
    expect(find.text(_note), findsNothing);
    await t.tap(find.text('Snooze for'));
    await t.pumpAndSettle();
    await t.tap(find.text('10 min').last);
    await t.pumpAndSettle();
    expect(app.snoozeSettings.minutes, 10);
  });
}
