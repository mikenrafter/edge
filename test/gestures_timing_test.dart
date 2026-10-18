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
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
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

import 'support/ecg_bad_connection_log_timeline.dart' show logThresholds;
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

  test('the defaults are the owner\'s device log line: double taps window '
      '2500 ms; ECG start 200, gap 150, confirm 750, extra sensitive', () {
    expect(EcgTapThresholds(), logThresholds());
    expect(GestureSettings.defaultRepeatWindowMs, 2500);
  });

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

    testWidgets('no ECG timings while double taps are the method', (t) async {
      await _pump(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: true,
            devMode: true,
            tapMethod: TapCountMethod.repeat,
            repeatWindowMs: 2500,
            onRepeatWindowMs: (_) {},
            thresholds: EcgTapThresholds(),
            onThresholds: (_) {},
          ));
      expect(_key('repeat-window:+'), findsOneWidget);
      expect(_key('ecg-threshold:start:+'), findsNothing);
      expect(_key('ecg-threshold:gap:+'), findsNothing);
      expect(_key('ecg-threshold:confirm:+'), findsNothing);
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

  group('ECG touches (developer mode, WHOOP MG)', () {
    BandGesturesView ecgView(
            {bool dev = true,
            bool mg = true,
            ValueChanged<EcgTapThresholds>? on,
            ValueChanged<int>? onWindow}) =>
        BandGesturesView(
          chosen: const {},
          supported: _supported,
          ecgSupported: mg,
          devMode: dev,
          tapMethod: TapCountMethod.ecg,
          repeatWindowMs: 2500,
          onRepeatWindowMs: onWindow ?? (_) {},
          thresholds: EcgTapThresholds(),
          onThresholds: on,
        );

    testWidgets('start, gap and confirm only, each editing the shared value',
        (t) async {
      final seen = <EcgTapThresholds>[];
      await _pump(t, ecgView(on: seen.add));
      expect(section('Timing'), findsOneWidget);
      expect(find.text('200 ms'), findsOneWidget, reason: 'start default');
      expect(find.text('150 ms'), findsOneWidget, reason: 'gap default');
      expect(find.text('750 ms'), findsOneWidget, reason: 'confirm default');
      await t.tap(_key('ecg-threshold:start:+'));
      await t.tap(_key('ecg-threshold:gap:-'));
      await t.tap(_key('ecg-threshold:confirm:-'));
      expect(seen, [
        EcgTapThresholds(startMs: 250),
        EcgTapThresholds(gapMs: 100),
        EcgTapThresholds(confirmMs: 700),
      ]);
      expect(_key('repeat-window:+'), findsNothing);
      expect(_key('ecg-threshold:extra-sensitive'), findsNothing,
          reason: 'the switches stay in the Device lab; only timings here');
      expect(_key('ecg-threshold:tolerant-startup'), findsNothing);
      expect(_key('ecg-threshold:fallback'), findsNothing);
    });

    testWidgets('not in developer mode: a stored ECG choice shows the '
        'double-tap chain, with no ECG option, name or timing', (t) async {
      await _pump(t, ecgView(dev: false));
      expect(_key('ecg-threshold:start:+'), findsNothing);
      expect(_key('repeat-window:+'), findsOneWidget);
      expect(_key('tap-method:ecg'), findsNothing);
      expect(section('Count extra taps with'), findsNothing);
      expect(find.textContaining('ECG'), findsNothing);
      for (final (n, name) in const [
        (2, 'Double tap'),
        (3, '2 double taps'),
        (4, '3 double taps'),
        (5, '4 double taps'),
      ]) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), name);
      }
    });

    testWidgets('developer mode on a band without the sensor: double taps, '
        'ECG option dimmed', (t) async {
      await _pump(t, ecgView(mg: false));
      expect(_key('ecg-threshold:start:+'), findsNothing);
      expect(_key('repeat-window:+'), findsOneWidget);
      expect(_key('tap-method:ecg'), findsOneWidget);
      expect(isDimmed(t, find.text('ECG sensor touches')), isTrue);
    });
  });

  testWidgets('no gesture is labelled a draft, and the note says so no more',
      (t) async {
    expect(kExtendedGesturesNote.toLowerCase(), isNot(contains('draft')));
    for (final dev in [true, false]) {
      await _pump(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: true,
            devMode: dev,
            tapMethod: TapCountMethod.ecg,
          ));
      for (final n in [2, 3, 4, 5]) {
        await openGesturesTab(t, n);
        expect(find.textContaining(RegExp('draft', caseSensitive: false)),
            findsNothing,
            reason: 'tab $n, dev $dev');
      }
    }
  });

  group('360 pt, text scale 1.3: no overflow', () {
    for (final (label, tap, dev) in const [
      ('double taps', TapCountMethod.repeat, false),
      ('double taps, dev', TapCountMethod.repeat, true),
      ('ECG, dev', TapCountMethod.ecg, true),
    ]) {
      testWidgets(label, (t) async {
        await _pump(
            t,
            BandGesturesView(
              chosen: const {},
              supported: _supported,
              ecgSupported: true,
              devMode: dev,
              tapMethod: tap,
              repeatWindowMs: 2500,
              onRepeatWindowMs: (_) {},
              thresholds: EcgTapThresholds(),
              onThresholds: (_) {},
            ),
            scale: 1.3);
        for (final n in [2, 3]) {
          await openGesturesTab(t, n);
        }
        expect(t.takeException(), isNull);
      });
    }
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

    testWidgets('the ECG touch timings', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.runAsync(() => app.gestureSettings.setTapMethod(TapCountMethod.ecg));
      await pumpWired(
          t, const BandGestures(), caps(dev: true, ecg: true), app: app);
      await t.runAsync(() async {
        await t.tap(_key('ecg-threshold:start:+'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pump();
      expect(app.gestureSettings.ecgTapThresholds.startMs, 250);
      await pumpWired(
          t, const DeviceLab(), caps(dev: true, ecg: true), app: app);
      expect(find.text('250 ms'), findsOneWidget);
    });
  });
}
