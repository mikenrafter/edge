// The Gestures screen carries the timing settings of the counting mode in
// force, and the ECG gesture options are developer-mode only.
//
//  * repeated double taps: the pause between them (the same adjuster and the
//    same stored value as the Device lab);
//  * ECG touches: start, gap and confirm (developer mode on a WHOOP MG only);
//  * without developer mode a stored ECG choice shows as the double-tap chain,
//    and the same fallback is what the dispatcher uses (see
//    app_state_gesture_dispatch_test.dart).
// Nothing here is marked draft.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
  DeviceAction.torch,
};

Finder _key(String k) => find.byKey(ValueKey(k));

/// 360 pt wide, tall enough to build every row, at [scale] text scale.
Future<void> _pump(WidgetTester t, Widget w, {double scale = 1}) async {
  t.view.physicalSize = const Size(1080, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: w,
  ));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('repeated double taps: the pause', () {
    testWidgets('shown with its value and edits through the callback',
        (t) async {
      final values = <int>[];
      await _pump(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            repeatWindowMs: 2500,
            onRepeatWindowMs: values.add,
          ));
      expect(section('Timing'), findsOneWidget);
      expect(find.text('Pause between double taps'), findsOneWidget);
      expect(find.text('2500 ms'), findsOneWidget);
      await t.tap(_key('repeat-window:+'));
      await t.tap(_key('repeat-window:-'));
      expect(values, [2750, 2250]);
    });

    testWidgets('without extra taps there is no timing section', (t) async {
      await _pump(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            extraTaps: false,
            repeatWindowMs: 2500,
            onRepeatWindowMs: (_) {},
          ));
      expect(section('Timing'), findsNothing);
      expect(_key('repeat-window:+'), findsNothing);
    });
  });

  group('one store: Gestures and the Device lab edit the same setting', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_gestures_timing_test.db';
    });
    setUp(() async {
      FeatureFlags.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
    });

    Future<AppState> pumpWired(WidgetTester t, Widget screen, Capabilities caps,
        {required AppState app}) async {
      t.view.physicalSize = const Size(1080, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MultiProvider(
        key: UniqueKey(),
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider(
              create: (_) =>
                  ThemeController.seed(AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
          Provider<Capabilities>.value(value: caps),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.light), home: screen),
      ));
      for (var i = 0; i < 25; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      return app;
    }

    Capabilities caps({bool dev = false, bool ecg = false}) =>
        Capabilities(CapabilityInputs(
          platform: TargetPlatform.android,
          ecgPaired: ecg,
          devMode: dev,
        ));

    testWidgets('the pause', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await pumpWired(t, const BandGestures(), caps(), app: app);
      expect(app.gestureSettings.repeatTapWindowMs, 2500);
      await t.runAsync(() async {
        await t.tap(_key('repeat-window:+'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pump();
      expect(app.gestureSettings.repeatTapWindowMs, 2750);
      expect(find.text('2750 ms'), findsOneWidget);
      await pumpWired(t, const DeviceLab(), caps(dev: true), app: app);
      expect(find.text('2750 ms'), findsOneWidget,
          reason: 'the lab reads the value Gestures wrote');
    });

  });
}
