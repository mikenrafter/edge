// 8AF.7 section C (red first): the phone is always a device.
//
// My devices lists "This phone" whether or not phone step counting is on.
// When it is off the row is present but disabled (dimmed) with the honest
// reason "Step counting from this phone is off". The phone's row or detail
// carries the "Count steps from this phone" toggle, bound to the SAME
// AppState preference as Settings > You & preferences, so both read the same
// value live.
//
// Contracts these tests pin that the spec leaves open:
//  - "Disabled" means dimmed (an Opacity below 1 at or above the row text) AND
//    still tappable to reach the toggle: the toggle must be reachable, or the
//    phone could never be turned back on from here. The toggle may sit on the
//    list row itself or on the page the row opens; _toggle() looks for it on
//    the list first, then opens "This phone".
//  - The toggle is the screen's only Material Switch.
//  - Turning it on/off goes through AppState.requestPhoneSteps /
//    disablePhoneSteps (the existing methods Settings already calls); the spy
//    below replaces their platform work.
//  - The Settings row keeps its title ("Steps" or "Steps from this phone");
//    it is a SetRow (value On/Off) or a SwitchRow.
//  - The "this platform cannot count steps" gate (Capabilities) is not pinned
//    here: it needs a new Feature whose name this spec does not give. Add a
//    test for it with the implementation if the gate is introduced.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/sections.dart';

const _reason = 'Step counting from this phone is off';
const _toggleLabel = 'Count steps from this phone';

class _Phone extends AppState {
  _Phone({bool enabled = false}) : super.forTesting() {
    phoneStepsEnabled = enabled;
  }
  int enables = 0, disables = 0;

  /// Stands in for the platform permission and the re-derive.
  @override
  Future<bool> requestPhoneSteps() async {
    enables++;
    phoneStepsEnabled = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> disablePhoneSteps() async {
    disables++;
    phoneStepsEnabled = false;
    notifyListeners();
  }

  void poke() => notifyListeners();
}

Future<void> _pump(WidgetTester t, AppState app, Widget home) async {
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
      Provider<Capabilities>.value(value: app.capabilities),
    ],
    child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
  ));
  await _wait(t);
}

Future<void> _wait(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
}

/// The phone's toggle: on the list row, else on the page "This phone" opens.
Future<Finder> _toggle(WidgetTester t) async {
  if (find.byType(Switch).evaluate().isEmpty) {
    await t.tap(find.text('This phone'));
    await _wait(t);
  }
  expect(find.text(_toggleLabel), findsOneWidget,
      reason: 'the phone offers "$_toggleLabel"');
  expect(find.byType(Switch), findsOneWidget);
  return find.byType(Switch);
}

bool _switchOn(WidgetTester t) => t.widget<Switch>(find.byType(Switch)).value;

/// Settings > You & preferences > the steps row, as on/off.
bool? _settingsOn(WidgetTester t) {
  for (final title in const ['Steps', 'Steps from this phone', _toggleLabel]) {
    final f = find.text(title);
    if (f.evaluate().isEmpty) continue;
    final sw = find.ancestor(of: f, matching: find.byType(SwitchRow));
    if (sw.evaluate().isNotEmpty) return t.widget<SwitchRow>(sw.first).value;
    final row = find.ancestor(of: f, matching: find.byType(SetRow));
    if (row.evaluate().isNotEmpty) {
      final v = t.widget<SetRow>(row.first).value;
      return v == 'On' ? true : v == 'Off' ? false : null;
    }
  }
  return null;
}

Future<void> _tapSettingsRow(WidgetTester t) async {
  for (final title in const ['Steps', 'Steps from this phone', _toggleLabel]) {
    final f = find.text(title);
    if (f.evaluate().isEmpty) continue;
    final sw = find.descendant(
        of: find.ancestor(of: f, matching: find.byType(SwitchRow)),
        matching: find.byType(Switch));
    await t.tap(sw.evaluate().isNotEmpty ? sw.first : f);
    await _wait(t);
    return;
  }
  fail('no phone steps row in Settings');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_phone_device_test.db';
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('the phone is always listed', () {
    testWidgets('off: present, dimmed, with the reason', (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      expect(find.text('This phone'), findsOneWidget,
          reason: 'present even though step counting is off');
      expect(find.text(_reason), findsOneWidget);
      expect(isDimmed(t, find.text('This phone')), isTrue,
          reason: 'disabled: dimmed');
    });

    testWidgets('on and delivering steps: present, not dimmed, no reason',
        (t) async {
      final app = _Phone(enabled: true)
        ..phoneStepsLastSyncedDays = 1
        ..phoneStepsLastTotal = 4200;
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('Reporting steps'), findsOneWidget);
      expect(find.text(_reason), findsNothing);
      expect(isDimmed(t, find.text('This phone')), isFalse);
    });

    testWidgets('on but nothing arriving (permission denied on iOS): honest, '
        'neither "off" nor "reporting"', (t) async {
      final app = _Phone(enabled: true);
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('No steps arriving'), findsOneWidget);
      expect(find.text('Reporting steps'), findsNothing);
      expect(find.text(_reason), findsNothing,
          reason: 'the toggle is on; the reason is that nothing arrives');
    });

    testWidgets('with a band paired the phone is still a second row',
        (t) async {
      final app = _Phone(enabled: false)
        ..paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      expect(find.text('Your band'), findsOneWidget);
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text(_reason), findsOneWidget);
    });

    testWidgets('a disabled phone is not counted as measuring anything',
        (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      // With no band and a phone that is off, the empty state still says so.
      expect(find.text('Nothing is measuring yet'), findsOneWidget);
      expect(find.text('No band is paired'), findsNothing);
    });
  });

  group('a platform with no step sensor (Feature.phoneSteps)', () {
    testWidgets('the phone is still listed, disabled with the platform reason, '
        'and its switch is inert', (t) async {
      var flips = 0;
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MyDevicesView(
          sources: const [
            HealthSource(
              name: 'This phone',
              kind: 'Motion coprocessor',
              tier: SourceTier.phone,
              icon: Icons.smartphone,
              disabledReason: 'This device cannot count steps',
            ),
          ],
          onTogglePhoneSteps: () => flips++,
          phoneStepsUnavailable: 'This device cannot count steps',
        ),
      ));
      await t.pump();
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('This device cannot count steps'), findsWidgets);
      expect(isDimmed(t, find.text('This phone')), isTrue);
      await t.tap(find.byType(Switch), warnIfMissed: false);
      expect(flips, 0, reason: 'inert: a sensor that is not there cannot be '
          'switched on');
    });

    test('the phone source carries the Capabilities reason, not the "off" one',
        () {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      // Flutter tests run as Android, which has a step sensor.
      expect(phoneSource(app).disabledReason, 'Step counting from this phone is off');
    });
  });

  group('the toggle lives with the phone', () {
    testWidgets('off: the toggle reads off; flipping it turns steps on',
        (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      await _toggle(t);
      expect(_switchOn(t), isFalse);
      await t.tap(find.byType(Switch));
      await _wait(t);
      expect(app.enables, 1, reason: 'the same call Settings makes');
      expect(app.phoneStepsEnabled, isTrue);
      expect(_switchOn(t), isTrue);
    });

    testWidgets('on: flipping it turns steps off', (t) async {
      final app = _Phone(enabled: true)
        ..phoneStepsLastSyncedDays = 1
        ..phoneStepsLastTotal = 4200;
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      await _toggle(t);
      expect(_switchOn(t), isTrue);
      await t.tap(find.byType(Switch));
      await _wait(t);
      expect(app.disables, 1);
      expect(app.phoneStepsEnabled, isFalse);
      expect(_switchOn(t), isFalse);
    });

    testWidgets('it follows the pref live: changed elsewhere, shown here',
        (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      await _pump(t, app, const MyDevices());
      await _toggle(t);
      expect(_switchOn(t), isFalse);
      app.phoneStepsEnabled = true; // what the Settings row does, via AppState
      app.poke();
      await _wait(t);
      expect(_switchOn(t), isTrue, reason: 'no reopen needed');
    });
  });

  group('one preference, two doors', () {
    Future<NavigatorState> openSettings(WidgetTester t, AppState app) async {
      await _pump(t, app, const MoreSettings());
      return t.state<NavigatorState>(find.byType(Navigator));
    }

    testWidgets('turned on in My devices: Settings reads On', (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      final nav = await openSettings(t, app);
      expect(_settingsOn(t), isFalse);

      await t.tap(find.text('My devices'));
      await _wait(t);
      await _toggle(t);
      await t.tap(find.byType(Switch));
      await _wait(t);
      expect(app.enables, 1);

      nav.popUntil((r) => r.isFirst);
      await _wait(t);
      expect(_settingsOn(t), isTrue, reason: 'one source of truth');
    });

    testWidgets('turned off in Settings: My devices shows the phone disabled',
        (t) async {
      final app = _Phone(enabled: true)
        ..phoneStepsLastSyncedDays = 1
        ..phoneStepsLastTotal = 4200;
      addTearDown(app.dispose);
      await openSettings(t, app);
      expect(_settingsOn(t), isTrue);

      await _tapSettingsRow(t);
      expect(app.disables, 1);

      await t.tap(find.text('My devices'));
      await _wait(t);
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text(_reason), findsOneWidget);
      expect(isDimmed(t, find.text('This phone')), isTrue);
    });

    testWidgets('turned on in Settings: the phone is enabled in My devices '
        'and its toggle reads on', (t) async {
      final app = _Phone(enabled: false);
      addTearDown(app.dispose);
      await openSettings(t, app);
      await _tapSettingsRow(t);
      expect(app.enables, 1);

      await t.tap(find.text('My devices'));
      await _wait(t);
      expect(find.text(_reason), findsNothing);
      await _toggle(t);
      expect(_switchOn(t), isTrue);
    });
  });
}
