// P5 (RED): the "Calculations" setting.
//
// ASSUMED API (new)
//
//   lib/state/prefs.dart (Prefs)
//     static const String calcPowerMode = 'calc_power_mode';     // the pref key
//     static CalcPowerMode get calcPowerModeValue;               // default
//         // balanced; an unknown or missing string is balanced
//     static void setCalcPowerMode(CalcPowerMode m);   // stores `m.name`
//         // ('maxBattery' | 'balanced' | 'eager') under the key above
//
//   AppState (lib/state/app_state.dart)
//     CalcPowerMode get calcPowerMode;                 // Prefs.calcPowerModeValue
//     Future<void> setCalcPowerMode(CalcPowerMode m);  // Prefs + coordinator
//
//   lib/ui2/profile/settings.dart
//     MoreSettingsView({... CalcPowerMode calcPowerMode = balanced,
//                       VoidCallback? onPickCalcPowerMode})
//         A SetRow keyed ValueKey('calc-power-row'), title 'Calculations',
//         value 'Maximum battery' | 'Balanced' | 'Eager', inside the
//         "Data & privacy" accordion (id settings_data_privacy); tapping it
//         calls onPickCalcPowerMode. (Existing tests that list that group's
//         rows (settings_regroup_test, g2_settings_layout_test) get the row
//         added alongside the implementation.)
//     Future<CalcPowerMode?> pickCalcPowerMode(BuildContext context,
//         CalcPowerMode current)
//         A sheet or dialog with three options keyed
//         ValueKey('calc-power-option-maxBattery' | '-balanced' | '-eager'),
//         each with its title ('Maximum battery', 'Balanced', 'Eager') and ONE
//         plain sentence (no percentages, no ETAs). Tapping one pops with it;
//         dismissing pops null.
//     MoreSettings (the stateful screen) wires the row to the picker and
//         AppState.setCalcPowerMode, and shows the saved mode.
//
// Failure mode today: none of these exist (compile error).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../fix8ai/support/g123_helpers.dart';

const _rowKey = ValueKey('calc-power-row');
Finder _option(CalcPowerMode m) => find.byKey(ValueKey('calc-power-option-${m.name}'));

const _titles = {
  CalcPowerMode.maxBattery: 'Maximum battery',
  CalcPowerMode.balanced: 'Balanced',
  CalcPowerMode.eager: 'Eager',
};

void _phone(WidgetTester t, {double width = 360, double height = 900}) {
  t.view.physicalSize = Size(width * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _wait(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
  await t.pumpAndSettle();
}

/// The list is lazy: scroll the row into the built, visible part.
Future<void> _reveal(WidgetTester t) async {
  await t.scrollUntilVisible(find.byKey(_rowKey), 300,
      scrollable: find.byType(Scrollable).first);
  await t.pump();
}

Widget _view(CalcPowerMode m, {VoidCallback? onPick, double scale = 1}) =>
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MoreSettingsView(
          calcPowerMode: m, onPickCalcPowerMode: onPick),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_p5_settings_test.db';
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  // One SharedPreferences instance for the file (Prefs caches it).
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  group('the preference', () {
    test('the default is balanced', () {
      expect(Prefs.calcPowerModeValue, CalcPowerMode.balanced);
    });

    test('it persists under calc_power_mode, by name', () async {
      expect(Prefs.calcPowerMode, 'calc_power_mode');
      for (final m in CalcPowerMode.values) {
        Prefs.setCalcPowerMode(m);
        expect(Prefs.calcPowerModeValue, m);
        final sp = await SharedPreferences.getInstance();
        expect(sp.getString('calc_power_mode'), m.name);
      }
    });

    test('an unknown stored value reads as balanced', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('calc_power_mode', 'turbo');
      expect(Prefs.calcPowerModeValue, CalcPowerMode.balanced);
    });

    test('AppState reads it at construction and writes it through', () async {
      Prefs.setCalcPowerMode(CalcPowerMode.eager);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect((app as dynamic).calcPowerMode, CalcPowerMode.eager);
      await (app as dynamic).setCalcPowerMode(CalcPowerMode.maxBattery);
      expect((app as dynamic).calcPowerMode, CalcPowerMode.maxBattery);
      expect(Prefs.calcPowerModeValue, CalcPowerMode.maxBattery);
    });
  });

  group('the row (MoreSettingsView)', () {
    testWidgets('in Data & privacy, titled Calculations, saying the mode',
        (t) async {
      _phone(t);
      for (final m in CalcPowerMode.values) {
        await t.pumpWidget(g123App(_view(m)));
        await g123Settle(t);
        await _reveal(t);
        final row = find.byKey(_rowKey);
        expect(row, findsOneWidget, reason: m.name);
        expect(
            find.descendant(
                of: accordionById('settings_data_privacy'), matching: row),
            findsOneWidget,
            reason: 'Settings > Data & privacy');
        expect(find.descendant(of: row, matching: find.text('Calculations')),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(_titles[m]!)),
            findsOneWidget,
            reason: m.name);
      }
    });

    testWidgets('a bare view defaults to balanced', (t) async {
      _phone(t);
      await t.pumpWidget(g123App(const MoreSettingsView()));
      await g123Settle(t);
      await _reveal(t);
      expect(
          find.descendant(
              of: find.byKey(_rowKey), matching: find.text('Balanced')),
          findsOneWidget);
    });

    testWidgets('tapping it asks to pick', (t) async {
      _phone(t);
      var taps = 0;
      await t.pumpWidget(
          g123App(_view(CalcPowerMode.balanced, onPick: () => taps++)));
      await g123Settle(t);
      await _reveal(t);
      await t.tap(find.byKey(_rowKey));
      await t.pump();
      expect(taps, 1);
    });

    testWidgets('360 pt wide at 1.5x text: no overflow', (t) async {
      _phone(t);
      await t.pumpWidget(g123App(_view(CalcPowerMode.maxBattery, scale: 1.5)));
      await g123Settle(t);
      await _reveal(t);
      expect(find.byKey(_rowKey), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('the picker', () {
    Future<void> open(WidgetTester t, CalcPowerMode current,
        {double scale = 1}) async {
      await t.pumpWidget(g123App(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => pickCalcPowerMode(c, current),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      )));
      await t.tap(find.text('open'));
      await g123Settle(t);
    }

    testWidgets('renders all three options, each with a title and one plain '
        'sentence, at 360 pt', (t) async {
      _phone(t);
      await open(t, CalcPowerMode.balanced);
      expect(t.takeException(), isNull);
      for (final m in CalcPowerMode.values) {
        expect(_option(m), findsOneWidget, reason: m.name);
        expect(find.descendant(of: _option(m), matching: find.text(_titles[m]!)),
            findsOneWidget);
        final texts = [
          for (final w in t.widgetList<Text>(
              find.descendant(of: _option(m), matching: find.byType(Text))))
            w.data ?? '',
        ];
        final sentence = texts.where((s) => s != _titles[m]).toList();
        expect(sentence, hasLength(1), reason: '${m.name}: one sentence');
        expect(sentence.single.trim().length, greaterThan(20));
        expect(sentence.single, isNot(contains('%')),
            reason: 'no percentages');
      }
    });

    testWidgets('still fits at 360 pt with 1.5x text', (t) async {
      _phone(t);
      await open(t, CalcPowerMode.eager, scale: 1.5);
      expect(t.takeException(), isNull);
      for (final m in CalcPowerMode.values) {
        expect(_option(m), findsOneWidget);
      }
    });

    testWidgets('tapping an option returns it', (t) async {
      _phone(t);
      CalcPowerMode? picked;
      await t.pumpWidget(g123App(Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                picked = await pickCalcPowerMode(c, CalcPowerMode.balanced),
            child: const Text('open'),
          ),
        ),
      )));
      await t.tap(find.text('open'));
      await g123Settle(t);
      await t.tap(_option(CalcPowerMode.eager));
      await g123Settle(t);
      expect(picked, CalcPowerMode.eager);
      expect(_option(CalcPowerMode.eager), findsNothing, reason: 'it closed');
    });

    testWidgets('dismissing returns null', (t) async {
      _phone(t);
      CalcPowerMode? picked = CalcPowerMode.balanced;
      var closed = false;
      await t.pumpWidget(g123App(Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () async {
              picked = await pickCalcPowerMode(c, CalcPowerMode.balanced);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      )));
      await t.tap(find.text('open'));
      await g123Settle(t);
      await t.tapAt(const Offset(2, 2)); // the scrim
      await g123Settle(t);
      expect(closed, isTrue);
      expect(picked, isNull);
    });
  });

  group('the screen (MoreSettings)', () {
    Future<AppState> pump(WidgetTester t) async {
      _phone(t);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider(
              create: (_) => ThemeController.seed(
                  AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
          Provider<Capabilities>.value(value: app.capabilities),
        ],
        child: MaterialApp(
            theme: buildTheme(Brightness.light), home: const MoreSettings()),
      ));
      await _wait(t);
      await _reveal(t);
      return app;
    }

    testWidgets('fresh install: the row says Balanced', (t) async {
      await pump(t);
      expect(
          find.descendant(
              of: find.byKey(_rowKey), matching: find.text('Balanced')),
          findsOneWidget);
    });

    testWidgets('choosing Eager saves it, tells AppState and updates the row; '
        'it is still there after a restart', (t) async {
      final app = await pump(t);
      await t.tap(find.byKey(_rowKey));
      await _wait(t);
      await t.tap(_option(CalcPowerMode.eager));
      await _wait(t);

      expect((app as dynamic).calcPowerMode, CalcPowerMode.eager);
      expect(Prefs.calcPowerModeValue, CalcPowerMode.eager);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('calc_power_mode'), 'eager');
      expect(
          find.descendant(of: find.byKey(_rowKey), matching: find.text('Eager')),
          findsOneWidget);

      // A second screen over the same storage: the saved mode, not the default.
      await t.pumpWidget(const SizedBox());
      await pump(t);
      expect(
          find.descendant(of: find.byKey(_rowKey), matching: find.text('Eager')),
          findsOneWidget);
    });

    testWidgets('dismissing the picker changes nothing', (t) async {
      final app = await pump(t);
      await t.tap(find.byKey(_rowKey));
      await _wait(t);
      await t.tapAt(const Offset(2, 2));
      await _wait(t);
      expect((app as dynamic).calcPowerMode, CalcPowerMode.balanced);
      expect(Prefs.calcPowerModeValue, CalcPowerMode.balanced);
    });
  });
}
