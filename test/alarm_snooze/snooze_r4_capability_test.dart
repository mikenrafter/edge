// Round 4 of the snooze safety review (Sol, alarm-snooze-sol-review3-2026-10-07
// .md, new defect 6): a retained snooze preference on a band that cannot drive
// it. RED. Enable Snooze on a Gen5, unpair, pair a Gen4: the preference is kept
// (unpair clears the chain, not the settings).
//
//  runtime  the snooze is OFF whenever the paired band lacks the capability:
//           a fire takes no band-prompt lease and arms no phone backstop, the
//           unknown stop opens no window and stores nothing, no gesture is
//           consumed. (Today `_snoozeOn` reads only the saved preference, so
//           the fire arms a backstop that notifies after the wearer dismissed
//           the native alarm.)
//  UI       the settings let the wearer switch a retained ON preference OFF on
//           an unsupported band (switch-off allowed); switching ON stays
//           disabled there; the four rows stay dimmed and inert.
//
// Contract used: `AppState.capabilities` / the paired band's generation
// (`engine.state.generation`) decide the capability, as Feature.alarmSnooze
// already does for the settings screen. Gen4's event 100 carries no readable
// cause.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_alarm_engine.dart';
import '../support/settings_sections.dart' show isDimmed;
import 'snooze_band_rig.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

const _rows = [
  'Double taps to dismiss',
  'Dismiss window',
  'Snooze for',
  'Stop escalating after',
];
const _dbName = 'openstrap_snooze_r4_capability_test.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runtime: the snooze is off on a band that cannot drive it', () {
    snoozeSuiteSetup(_dbName);

    late SnoozeBandRig rig;
    late DateTime t0;
    late NotificationSpy n;

    setUp(() => n = NotificationSpy()..install());
    tearDown(() async {
      n.uninstall();
      await rig.dispose();
    });

    Future<void> expectInert() async {
      await rig.fire(stamp: t0);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isEmpty,
          reason: 'no band-prompt lease for a snooze that cannot happen');
      expect(n.scheduled, isEmpty,
          reason: 'no backstop: the wearer dismisses the native alarm and '
              'would still get the later phone notification');

      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap, noBody: true);
      await rig.settle();
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(rig.app.snooze.consumesDoubleTaps, isFalse);
      expect(await storedWindow(), isNull);
      expect(await storedState(), isNull);
      expect(n.scheduled, isEmpty);
      expect(rig.engine.prompts.where((c) => c.enabled), isEmpty);
      expect(hapticWrites(rig), 0, reason: 'no confirm cue, no re-alarm');

      for (var i = 0; i < 2; i++) {
        rig.clock.advance(kSec * 1);
        final before = rig.app.deviceLab.entries.length;
        await rig.tap();
        expect(rig.app.deviceLab.entries.length, before + 1,
            reason: 'tap ${i + 1} is the wearer\'s ordinary gesture');
      }
    }

    test('a Gen4 paired with the preference still ON: a fire arms nothing, '
        'its stop starts nothing', () async {
      rig = await SnoozeBandRig.open(generation: 'gen4', snooze: true);
      t0 = rig.clock.now;
      expect(enabledOf(rig.app.snoozeSettings), isTrue,
          reason: 'precondition: the preference is retained');
      await expectInert();
    });

    test('Gen5 with snooze on, then the band is swapped for a Gen4 in the '
        'same process: the same', () async {
      rig = await SnoozeBandRig.open(generation: 'gen5', snooze: true);
      t0 = rig.clock.now;
      await rig.app.unpair();
      rig.engine.state.generation = 'gen4';
      rig.engine.state.connection = 'connected';
      expect(enabledOf(rig.app.snoozeSettings), isTrue,
          reason: 'precondition: unpair keeps the settings');
      await expectInert();
    });

    test('control: the same on a Gen5 band does arm the lease and the '
        'backstop', () async {
      rig = await SnoozeBandRig.open(generation: 'gen5', snooze: true);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty);
      expect(n.scheduled, isNotEmpty);
    });
  });

  group('UI: a retained ON preference can be switched off on a Gen4', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = '${_dbName}_ui';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<AppState> pumpScreen(WidgetTester t, String generation,
        {required bool on}) async {
      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.engine.state.generation = generation;
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
    Finder toggle() =>
        find.descendant(of: snoozeRow(), matching: find.byType(Switch));

    testWidgets('Gen4, preference ON: the switch shows ON and can be turned '
        'OFF; once off it cannot be turned back on', (t) async {
      final app = await pumpScreen(t, 'gen4', on: true);
      expect(t.widget<SwitchRow>(snoozeRow()).value, isTrue,
          reason: 'precondition: the retained preference is shown');
      expect(t.widget<Switch>(toggle()).onChanged, isNotNull,
          reason: 'the wearer cannot switch a retained ON preference off on '
              'a band that cannot drive it');

      await t.tap(toggle());
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pumpAndSettle();
      expect(enabledOf(app.snoozeSettings), isFalse);
      expect(t.widget<SwitchRow>(snoozeRow()).value, isFalse);
      expect(t.widget<Switch>(toggle()).onChanged, isNull,
          reason: 'switching ON stays disabled on this band');
    });

    testWidgets('Gen4, preference ON: the four rows stay dimmed and inert',
        (t) async {
      final app = await pumpScreen(t, 'gen4', on: true);
      for (final label in _rows) {
        expect(find.text(label), findsOneWidget, reason: label);
        expect(isDimmed(t, find.text(label)), isTrue, reason: label);
        await t.tap(find.text(label), warnIfMissed: false);
        await t.pumpAndSettle();
        expect(find.byType(SimpleDialog), findsNothing, reason: label);
      }
      expect(enabledOf(app.snoozeSettings), isTrue,
          reason: 'only the switch changes the preference');
    });

    testWidgets('Gen4, preference OFF: switching ON is disabled (control)',
        (t) async {
      await pumpScreen(t, 'gen4', on: false);
      expect(t.widget<Switch>(toggle()).onChanged, isNull);
    });

    testWidgets('Gen5, preference ON: the switch works both ways (control)',
        (t) async {
      final app = await pumpScreen(t, 'gen5', on: true);
      expect(t.widget<Switch>(toggle()).onChanged, isNotNull);
      await t.tap(toggle());
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pumpAndSettle();
      expect(enabledOf(app.snoozeSettings), isFalse);
      expect(t.widget<Switch>(toggle()).onChanged, isNotNull);
    });
  });
}
