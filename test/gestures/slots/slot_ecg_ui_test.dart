// ECG as an exclusive mode in the UI and the settings seam (GREEN additions):
//   * the Device lab's ECG switch shows the refusal and does not flip;
//   * a user who already has ECG on AND actions mapped keeps both, and the
//     double tap's tab says only ECG runs;
//   * the stored ECG switch only owns the double tap where it is in force
//     (GestureSettings.ecgInForce), so a stale switch is no dead end.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _label = 'Toggle ECG recording on double tap';
const _channel = MethodChannel('openstrap/device_actions');

Finder _refusal = find.byKey(const ValueKey('device-lab-ecg-refusal'));
Finder _note = find.byKey(const ValueKey('gesture-ecg-only-note'));

Finder _labSwitch() => find.descendant(
    of: find.ancestor(of: find.text(_label), matching: find.byType(Row)).first,
    matching: find.byType(Switch));

Future<void> _pumpLab(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

Future<void> _pumpGestures(WidgetTester t,
    {required bool ecg,
    Set<DeviceAction> chosen = const {DeviceAction.logWater}}) async {
  t.view.physicalSize = const Size(390 * 3, 3200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: BandGesturesView(
      chosen: chosen,
      supported: const {DeviceAction.none, DeviceAction.logWater},
      tapActions: const {3: {DeviceAction.logWater}},
      ecgOnDoubleTap: ecg,
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() {
    Prefs.setString(kGesturesTabPref, '');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'capabilities') return <String>[];
      return false;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('Device lab: ECG on double tap', () {
    testWidgets('a refusal shows its reason and the switch does not flip',
        (t) async {
      final asked = <bool>[];
      await _pumpLab(
          t,
          DeviceLabView(
            ecgSupported: true,
            onTryEcgOnDoubleTap: (on) async {
              asked.add(on);
              return const ActionToggleRefusedExclusive(
                  kEcgExclusiveTurnOthersOff);
            },
          ));
      expect(_refusal, findsNothing);
      await t.tap(_labSwitch());
      await t.pumpAndSettle();
      expect(asked, [true]);
      expect(t.widget<Text>(_refusal).data, kEcgExclusiveTurnOthersOff);
      expect(t.widget<Switch>(_labSwitch()).value, isFalse);
    });

    testWidgets('an ok answer shows nothing and clears an earlier refusal',
        (t) async {
      final answers = <ActionToggleResult>[
        const ActionToggleRefusedExclusive(kEcgExclusiveTurnOthersOff),
        const ActionToggleOk(),
      ];
      await _pumpLab(
          t,
          DeviceLabView(
            ecgSupported: true,
            onTryEcgOnDoubleTap: (_) async => answers.removeAt(0),
          ));
      await t.tap(_labSwitch());
      await t.pumpAndSettle();
      expect(_refusal, findsOneWidget);
      await t.tap(_labSwitch());
      await t.pumpAndSettle();
      expect(_refusal, findsNothing);
    });

    testWidgets('without the new callback the old one still drives the switch',
        (t) async {
      final asked = <bool>[];
      await _pumpLab(
          t, DeviceLabView(ecgSupported: true, onEcgOnDoubleTap: asked.add));
      await t.tap(_labSwitch());
      await t.pumpAndSettle();
      expect(asked, [true]);
    });
  });

  group('an older config: ECG on and actions mapped', () {
    testWidgets('the double tap tab says only ECG runs; other tabs do not',
        (t) async {
      await _pumpGestures(t, ecg: true);
      expect(t.widget<Text>(_note).data, kEcgOnlyRunsNote);
      await t.ensureVisible(find.byKey(const ValueKey('gestures-tab:3')));
      await t.tap(find.byKey(const ValueKey('gestures-tab:3')));
      await t.pumpAndSettle();
      expect(_note, findsNothing);
    });

    testWidgets('no note with ECG off, or with no actions on the double tap',
        (t) async {
      await _pumpGestures(t, ecg: false);
      expect(_note, findsNothing);
      await _pumpGestures(t, ecg: true, chosen: const {});
      expect(_note, findsNothing);
    });
  });

  group('GestureSettings.ecgInForce', () {
    Future<GestureSettings> boot() async {
      SharedPreferences.setMockInitialValues({});
      final s = GestureSettings();
      await s.bootstrap();
      return s;
    }

    test('a stored ECG switch that is not in force refuses nothing',
        () async {
      final s = await boot();
      await s.setEcgOnDoubleTap(true);
      var inForce = false;
      s.ecgInForce = () => inForce;
      expect(s.ecgActive, isFalse);
      expect(await s.trySetAction('double', DeviceAction.logWater, true),
          isA<ActionToggleOk>());
      expect(s.doubleTapActions, {DeviceAction.logWater});
      inForce = true;
      expect(s.ecgActive, isTrue);
      expect(await s.trySetAction('double', DeviceAction.markMoment, true),
          isA<ActionToggleRefusedExclusive>());
    });

    test('loading never changes a config that has both', () async {
      SharedPreferences.setMockInitialValues({
        'gesture_ecg_on_double_tap': true,
        'gesture_double_tap_actions': GestureSettings.maskOf(
            {DeviceAction.logWater}),
      });
      final s = GestureSettings();
      await s.bootstrap();
      expect(s.ecgOnDoubleTap, isTrue);
      expect(s.doubleTapActions, {DeviceAction.logWater});
    });
  });
}
