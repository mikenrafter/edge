// Bedtime breathing cues vs the Device lab (review P1). The Bedtime page is
// pushed ON TOP of the Device lab, whose LabSession stays mounted, so the band
// queue keeps `labOpen` true and rejects every immediate non-lab job: each
// bedtime cue is refused and the session ends after three without a buzz.
//
// Intended design under test: the lab keeps its own exclusivity semantics and
// YIELDS `labOpen` only while an explore page (the Bedtime page) is on top of
// it, taking it back when that page closes. Other pushed lab pages (the pattern
// probe) are lab work and keep it open. The queue's immediate/budget checks are
// NOT weakened (see band_queue_immediate_test.dart: lab open => rejected).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_screen.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_bedtime_lab_yield_test.db';
  });
  setUp(() async {
    FeatureFlags.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setBool(Prefs.exploreBedtime, true);
  });

  Future<AppState> pumpLab(WidgetTester t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
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
            value: Capabilities(CapabilityInputs(
          platform: TargetPlatform.android,
          generation: null,
          ecgPaired: false,
          ecgLive: false,
          connected: false,
          devMode: true,
          flagsOff: const {},
          updateChecksBuild: false,
          healthShareBuild: false,
          healthShareConsent: false,
        ))),
      ],
      child: MaterialApp(
          theme: buildTheme(Brightness.light), home: const DeviceLab()),
    ));
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      if (i >= 4) break;
    }
    await t.tap(find.byKey(const ValueKey('device-lab-tab:probes')));
    await t.pump();
    await t.pump();
    return app;
  }

  testWidgets('the Bedtime page on top of the Device lab yields the lab, and '
      'the lab takes it back when the page closes', (t) async {
    final app = await pumpLab(t);
    expect(app.haptics.labOpen, isTrue, reason: 'the lab is on screen');

    await t.tap(find.text('Bedtime breathing cues'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(BedtimeScreen), findsOneWidget);
    expect(app.haptics.labOpen, isFalse,
        reason: 'the lab is under the Bedtime page: while labOpen is true the '
            'queue rejects every immediate bedtime cue');

    Navigator.of(t.element(find.byType(BedtimeScreen))).pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(BedtimeScreen), findsNothing);
    expect(app.haptics.labOpen, isTrue,
        reason: 'back on the lab: its own exclusivity applies again');
  });

  // GUARD (passes today and must keep passing): the yield is for explore pages
  // only. Some other page pushed over the lab (the pattern probe is lab work)
  // does not make the lab give up exclusivity.
  testWidgets('guard: a non-explore page pushed over the lab does not yield it',
      (t) async {
    final calls = <String>[];
    final runner = HardwareProbeRunner(
      lab: DeviceLabLog(),
      sendBuzz: (onReply) async => true,
      sendPattern: (e, l, onReply) async => true,
      isConnected: () => true,
      ecgSupported: () => true,
      ecgBusy: () => false,
      beginEcg: () async => false,
      endEcg: () async {},
      isEcgAlive: () => false,
      beginLab: () => calls.add('begin'),
      endLab: () => calls.add('end'),
    );
    await t.pumpWidget(MaterialApp(
      home: LabSession(runner: runner, child: const Text('lab')),
    ));
    final nav = Navigator.of(t.element(find.text('lab')));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('probe page')));
    await t.pumpAndSettle();
    expect(find.text('probe page'), findsOneWidget);
    expect(calls, ['begin']);
  });
}
