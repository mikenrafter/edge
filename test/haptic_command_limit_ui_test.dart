// The band command limit's control (rule 6). It was a developer setting in
// Settings > Developer; it is now on Haptics > Band, in the Safety accordion,
// where the wearer can see it WITHOUT developer mode, next to the copy that
// names it ("our own limit of N commands per 2 minutes") and the read-out of
// the commands left. One control only: the Developer group no longer has it.
// The ledger still reads Prefs.hapticCommandLimit on every use, so a change
// takes effect at once.
//
// New API pinned:
//   HapticsSettingsView({int commandLimit = 30,
//                        ValueChanged<int>? onCommandLimit})
//     In Safety on the Band tab (devMode or not), a row keyed
//     `haptics-command-limit` holding a Slider from 10 to 60 whose value is
//     `commandLimit`, and a text that says the number and the 2 minutes.
//     Moving the slider calls `onCommandLimit` with a whole number from 10 to
//     60. The Safety copy says "our own limit of <commandLimit> commands per 2
//     minutes" and the read-out "<left> of <commandLimit> band commands left in
//     the last 2 minutes".
//   HapticsSettings (the stateful route) writes the value through
//     Prefs.setHapticCommandLimit and rebuilds with the ledger's limitNow.
//   MoreSettingsView no longer has hapticCommandLimit / onHapticCommandLimit
//     and the Developer group has no `developer-haptic-limit` row.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/dart_source_lexical.dart';
import 'support/haptics_screen_support.dart' show openHapticsTab;
import 'support/settings_sections.dart' show pumpTall, section;

const _row = ValueKey('haptics-command-limit');
const _oldRow = ValueKey('developer-haptic-limit');

Future<void> _pumpSettings(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: LocaleController.seed(null),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

Finder _slider() =>
    find.descendant(of: find.byKey(_row), matching: find.byType(Slider));

HapticsSettingsView _hub({
  int left = 30,
  int? limit,
  bool devMode = false,
  ValueChanged<int>? onLimit,
}) =>
    limit == null && onLimit == null
        ? HapticsSettingsView(
            patterns: const [],
            usageOf: (_) => 0,
            profile: HapticDeviceProfile.whoopMg,
            allowLong: false,
            devMode: devMode,
            commandsLeft: left,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
          )
        : HapticsSettingsView(
            patterns: const [],
            usageOf: (_) => 0,
            profile: HapticDeviceProfile.whoopMg,
            allowLong: false,
            devMode: devMode,
            commandsLeft: left,
            commandLimit: limit ?? 30,
            onCommandLimit: onLimit,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
          );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The accordions of every screen below read their open/closed state through
  // the settings repository's queue; without stored preferences that read never
  // answers and would hold up the stateful test at the end of the file.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('Settings > Developer: the limit is no longer here', () {
    testWidgets('developer mode on: no limit row, no slider, no heading',
        (t) async {
      await _pumpSettings(t, const MoreSettingsView(devMode: true));
      expect(section('Developer'), findsOneWidget,
          reason: 'the group itself is still there');
      expect(find.byKey(_oldRow), findsNothing);
      expect(find.text('Band haptic limit'), findsNothing);
      expect(find.descendant(of: section('Developer'), matching: find.byType(Slider)),
          findsNothing);
      expect(find.textContaining('commands in any 2 minutes'), findsNothing);
    });

    testWidgets('developer mode off: nor is it anywhere on the page', (t) async {
      await _pumpSettings(t, const MoreSettingsView());
      expect(find.byKey(_oldRow), findsNothing);
      expect(find.byKey(_row), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    test('source: one control only, the Settings screen has no copy of it', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final code = codeOnly(src);
      for (final gone in [
        '_HapticLimitRow',
        'hapticCommandLimit',
        'onHapticCommandLimit',
        'setHapticCommandLimit',
        '_hapticLimit',
      ]) {
        expect(code, isNot(contains(gone)), reason: gone);
      }
      expect(src, isNot(contains('developer-haptic-limit')));
    });

    test('source: the Haptics route is the one place that writes the setting',
        () {
      final code = codeOnly(
          File('lib/ui2/profile/haptics_settings.dart').readAsStringSync());
      expect(code, contains('setHapticCommandLimit('));
      expect(code, contains('onCommandLimit'));
    });
  });

  group('Settings > Haptics > Band: Safety', () {
    testWidgets('the row is in the Safety accordion, with developer mode off',
        (t) async {
      await pumpTall(t, _hub(limit: 30));
      await openHapticsTab(t, 'band');
      expect(find.byKey(_row), findsOneWidget);
      expect(find.descendant(of: section('Safety'), matching: find.byKey(_row)),
          findsOneWidget);
    });

    testWidgets('and with developer mode on, once', (t) async {
      await pumpTall(t, _hub(limit: 30, devMode: true));
      await openHapticsTab(t, 'band');
      expect(find.byKey(_row), findsOneWidget);
    });

    testWidgets('only on the Band tab', (t) async {
      await pumpTall(t, _hub(limit: 30));
      await openHapticsTab(t, 'band');
      expect(find.byKey(_row), findsOneWidget);
      for (final tab in ['patterns', 'alerts', 'activity', 'cues']) {
        await openHapticsTab(t, tab);
        expect(find.byKey(_row), findsNothing, reason: tab);
      }
    });

    testWidgets('a slider from 10 to 60 at the value given, 30 by default',
        (t) async {
      await pumpTall(t, _hub(limit: 30));
      await openHapticsTab(t, 'band');
      var s = t.widget<Slider>(_slider());
      expect(s.min, 10);
      expect(s.max, 60);
      expect(s.value, 30);
      await pumpTall(t, _hub(limit: 45));
      await openHapticsTab(t, 'band');
      s = t.widget<Slider>(_slider());
      expect(s.value, 45);
    });

    testWidgets('it says the number and what it counts', (t) async {
      await pumpTall(t, _hub(limit: 45));
      await openHapticsTab(t, 'band');
      expect(
          find.descendant(of: find.byKey(_row), matching: find.textContaining('45')),
          findsWidgets);
      expect(
          find.descendant(
              of: find.byKey(_row), matching: find.textContaining('2 minutes')),
          findsWidgets);
    });

    testWidgets('moving it to either end reports 60 and 10, never beyond',
        (t) async {
      final seen = <int>[];
      await pumpTall(t, _hub(limit: 30, onLimit: seen.add));
      await openHapticsTab(t, 'band');
      await t.drag(_slider(), const Offset(4000, 0));
      await t.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last, 60);
      seen.clear();
      await t.drag(_slider(), const Offset(-4000, 0));
      await t.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last, 10);
      expect(seen, everyElement(inInclusiveRange(10, 60)));
    });

    testWidgets('the Safety copy names the limit in force', (t) async {
      await pumpTall(t, _hub(limit: 45));
      await openHapticsTab(t, 'band');
      expect(find.textContaining('our own limit of 45 commands per 2 minutes'),
          findsOneWidget);
      expect(find.textContaining('our own limit of 30 commands'), findsNothing);
      await pumpTall(t, _hub(limit: 12));
      await openHapticsTab(t, 'band');
      expect(find.textContaining('our own limit of 12 commands per 2 minutes'),
          findsOneWidget);
    });

    testWidgets('the read-out names the limit in force, not a fixed 30',
        (t) async {
      await pumpTall(t, _hub(left: 12, limit: 20));
      await openHapticsTab(t, 'band');
      expect(find.text('12 of 20 band commands left in the last 2 minutes'),
          findsOneWidget);
      await pumpTall(t, _hub(left: 55, limit: 60));
      await openHapticsTab(t, 'band');
      expect(find.text('55 of 60 band commands left in the last 2 minutes'),
          findsOneWidget);
    });

    testWidgets('without a limit given it still reads "of 30"', (t) async {
      await pumpTall(t, _hub(left: 30));
      await openHapticsTab(t, 'band');
      expect(find.text('30 of 30 band commands left in the last 2 minutes'),
          findsOneWidget);
      expect(find.textContaining('our own limit of 30 commands per 2 minutes'),
          findsOneWidget);
    });

    testWidgets('the copy, the control and the read-out move together',
        (t) async {
      // Safety reads top to bottom: the checkbox (with the copy), the control,
      // the read-out. They are all in the one accordion.
      await pumpTall(t, _hub(left: 7, limit: 40));
      await openHapticsTab(t, 'band');
      for (final f in [
        find.byKey(const ValueKey('haptics-allow-long')),
        find.byKey(_row),
        find.text('7 of 40 band commands left in the last 2 minutes'),
      ]) {
        expect(find.descendant(of: section('Safety'), matching: f),
            findsOneWidget);
      }
    });
  });

  group('the stateful Haptics route writes the setting and the ledger follows',
      () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_haptic_command_limit_ui_test.db';
    });

    // One test: the settings repository serialises on a static queue, which a
    // test that ends mid-load would leave waiting for the next one.
    testWidgets('moving the slider sets the pref, the ledger and the copy',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      Prefs.setHapticCommandLimit(25);

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      // The same ledger the real band queue budgets with: it asks Prefs on
      // every use, so a change is live with no restart.
      final BandCommandLedger ledger = app.haptics.ledger;
      expect(ledger.limitNow, 25);

      t.view.physicalSize = const Size(1170, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider(
              create: (_) =>
                  ThemeController.seed(AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
          Provider<Capabilities>.value(
            value: Capabilities(const CapabilityInputs(
              platform: TargetPlatform.android,
              generation: null,
              ecgPaired: false,
              ecgLive: false,
              connected: false,
              devMode: false,
              flagsOff: {},
              updateChecksBuild: false,
              healthShareBuild: false,
              healthShareConsent: false,
            )),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const HapticsSettings(tab: HapticsTab.band),
        ),
      ));
      final loaded = find.byType(HapticsSettingsView);
      // The settings snapshot loads from sqflite in real time; a busy machine
      // (the suite runs files in parallel) can take a few seconds.
      for (var i = 0; i < 600; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
        if (i >= 4 && loaded.evaluate().isNotEmpty) break;
      }
      expect(loaded, findsOneWidget, reason: 'the route never finished loading');
      expect(find.byKey(_row), findsOneWidget,
          reason: 'visible without developer mode');
      expect(t.widget<Slider>(_slider()).value, 25,
          reason: 'it shows the limit in force');
      expect(find.textContaining('our own limit of 25 commands per 2 minutes'),
          findsOneWidget);

      await t.drag(_slider(), const Offset(4000, 0));
      await t.pumpAndSettle();
      expect(Prefs.hapticCommandLimit, 60);
      expect(ledger.limitNow, 60, reason: 'the ledger follows at once');
      expect(t.widget<Slider>(_slider()).value, 60);
      expect(find.textContaining('our own limit of 60 commands per 2 minutes'),
          findsOneWidget);
      expect(find.textContaining('of 60 band commands left'), findsOneWidget);

      await t.drag(_slider(), const Offset(-4000, 0));
      await t.pumpAndSettle();
      expect(Prefs.hapticCommandLimit, 10);
      expect(ledger.limitNow, 10);
      expect(find.textContaining('our own limit of 10 commands per 2 minutes'),
          findsOneWidget);
    });
  });
}
