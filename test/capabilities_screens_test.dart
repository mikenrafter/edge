// Each migrated screen asks the Capabilities it is given and nothing
// else. These pump the real screens over an AppState that has NO band, then
// hand them a Capabilities built directly: if a screen still derived its own
// gate from AppState, Prefs, or the platform, the Capabilities would not win.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart'
    show showSignalPriorityEntry, showSourceCatalogEntry;
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/calm_breathing.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show HealthData, HealthScreen;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/haptics_screen_support.dart' show openHapticsTab;
import 'support/settings_sections.dart';

Capabilities _caps({
  TargetPlatform platform = TargetPlatform.android,
  String? generation,
  bool ecgPaired = false,
  bool ecgLive = false,
  bool connected = false,
  bool devMode = false,
  Set<FeatureFlag> flagsOff = const {},
  bool updateChecksBuild = false,
  bool healthShareBuild = false,
  bool healthShareConsent = false,
}) =>
    Capabilities(CapabilityInputs(
      platform: platform,
      generation: generation,
      ecgPaired: ecgPaired,
      ecgLive: ecgLive,
      connected: connected,
      devMode: devMode,
      flagsOff: flagsOff,
      updateChecksBuild: updateChecksBuild,
      healthShareBuild: healthShareBuild,
      healthShareConsent: healthShareConsent,
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The screens read their histories from sqflite. The connection is left open
  // at the end: closing it while a screen's last read is in flight hangs the
  // runner, and the file lives in the test sandbox.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_capabilities_screens_test.db';
  });
  setUp(() async {
    FeatureFlags.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  /// [caps] over a real AppState with no band: anything the screen still reads
  /// from the app (connection, ECG, generation, dev mode) says "no".
  Future<AppState> pump(WidgetTester t, Widget screen, Capabilities caps,
      {Finder? ready}) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    t.view.physicalSize = const Size(1170, 24000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      key: UniqueKey(),
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
            create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider(
            create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        Provider<Capabilities>.value(value: caps),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: screen),
    ));
    // The screens load from sqflite and prefs in real time.
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      if (i >= 4 && (ready == null || ready.evaluate().isNotEmpty)) break;
    }
    return app;
  }

  group('AppState feeds the inputs', () {
    test('a bare AppState has no link, no ECG, no dev mode, flags at default',
        () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final c = app.capabilities;
      expect(c.inputs.connected, isFalse);
      expect(c.inputs.ecgPaired, isFalse);
      expect(c.inputs.ecgLive, isFalse);
      expect(c.inputs.devMode, isFalse);
      expect(c.inputs.flagsOff, isEmpty);
      expect(c, app.capabilities, reason: 'equal inputs, equal value');
    });
    test('the paired MG and a flag move the answers', () {
      final app = AppState.forTesting()..pairedIsMaverick = true;
      addTearDown(app.dispose);
      expect(app.capabilities.of(Feature.ecgEntry), Availability.available);
      FeatureFlags.debugSet(FeatureFlag.tapClassifiers, false);
      expect(app.capabilities.of(Feature.extraTapCounting), Availability.hidden);
    });
    test('setDevMode stores it, announces it, and the capabilities follow', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      var told = 0;
      app.addListener(() => told++);
      app.setDevMode(true);
      addTearDown(() => app.setDevMode(false));
      expect(told, 1);
      expect(app.capabilities.of(Feature.developerMode),
          Availability.available);
      expect(Prefs.getBool(Prefs.devMode, false), isTrue);
    });
  });

  group('Settings (MoreSettings)', () {
    testWidgets('relay row follows relayEntry, not the platform', (t) async {
      await pump(t, const MoreSettings(), _caps());
      expect(find.text('App notifications on the band'), findsOneWidget);
    });
    testWidgets('relay row hidden when the flag is off on Android', (t) async {
      await pump(t, const MoreSettings(),
          _caps(flagsOff: {FeatureFlag.nativeRelay}));
      expect(find.text('App notifications on the band'), findsNothing);
    });
    testWidgets('relay row hidden off Android', (t) async {
      await pump(t, const MoreSettings(),
          _caps(platform: TargetPlatform.iOS));
      expect(find.text('App notifications on the band'), findsNothing);
    });
    testWidgets('Developer section follows developerMode, not Prefs', (t) async {
      await pump(t, const MoreSettings(), _caps());
      expect(section('Developer'), findsNothing);
      await pump(t, const MoreSettings(), _caps(devMode: true));
      expect(section('Developer'), findsOneWidget);
    });
    testWidgets('health share and update checks rows follow their features',
        (t) async {
      await pump(t, const MoreSettings(), _caps());
      expect(find.text('Contribute my health data'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
      await pump(
          t,
          const MoreSettings(),
          _caps(healthShareConsent: true, updateChecksBuild: true));
      expect(find.text('Contribute my health data'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
    });
  });

  group('Band gestures', () {
    testWidgets('tap rows are hidden when tapClassifiers is off', (t) async {
      await pump(t, const BandGestures(), _caps(devMode: true));
      expect(find.text('Count extra taps with'), findsOneWidget);
      await pump(t, const BandGestures(),
          _caps(devMode: true, flagsOff: {FeatureFlag.tapClassifiers}));
      expect(find.text('Count extra taps with'), findsNothing);
      expect(find.byKey(const ValueKey('gestures-tab:3')), findsNothing);
    });
    testWidgets('the Device lab link under Haptics follows developer mode',
        (t) async {
      await pump(t, const BandGestures(), _caps());
      expect(find.byKey(const ValueKey('gestures-open-haptics')), findsOneWidget);
      expect(find.byKey(const ValueKey('gestures-open-device-lab')), findsNothing);
      await pump(t, const BandGestures(), _caps(devMode: true));
      expect(find.byKey(const ValueKey('gestures-open-device-lab')), findsOneWidget);
    });
    testWidgets('the ECG options follow developerMode: absent without it',
        (t) async {
      await pump(t, const BandGestures(), _caps(ecgPaired: true));
      expect(find.text('ECG sensor touches'), findsNothing);
      expect(find.text('Count extra taps with'), findsNothing);
      expect(find.textContaining('ECG'), findsNothing);
      expect(find.byKey(const ValueKey('gestures-tab:3')), findsOneWidget,
          reason: 'the double-tap counts stay for everyone');
    });
    testWidgets('ECG method is dimmed and inert without the ECG feature, '
        'live without it from AppState', (t) async {
      await pump(t, const BandGestures(), _caps(devMode: true));
      final off = find.text('ECG sensor touches');
      expect(off, findsOneWidget);
      expect(isDimmed(t, off), isTrue);
      await pump(t, const BandGestures(), _caps(devMode: true, ecgPaired: true));
      expect(isDimmed(t, find.text('ECG sensor touches')), isFalse);
    });
  });

  group('Device lab', () {
    testWidgets('tap tools follow deviceLabTapTools', (t) async {
      await pump(t, const DeviceLab(), _caps());
      expect(find.text('ECG on double tap'), findsOneWidget);
      await pump(
          t, const DeviceLab(), _caps(flagsOff: {FeatureFlag.tapClassifiers}));
      expect(find.text('ECG on double tap'), findsNothing);
    });
    testWidgets('the ECG switch says why it is off', (t) async {
      await pump(t, const DeviceLab(), _caps());
      expect(find.text('This band has no ECG sensor'), findsOneWidget);
      await pump(t, const DeviceLab(), _caps(ecgPaired: true));
      expect(find.text('This band has no ECG sensor'), findsNothing);
    });
  });

  group('Haptics hub', () {
    // One test, several screens: the settings repository serialises on a
    // static queue, which a test that ends mid-load would leave waiting for the
    // next one.
    testWidgets('dev mode, the link and the MG vocabulary follow Capabilities',
        (t) async {
      final loaded = find.byType(HapticsSettingsView);
      Future<void> hub(Capabilities c) =>
          pump(t, const HapticsSettings(), c, ready: loaded);

      await hub(_caps());
      await openHapticsTab(t, 'band');
      expect(find.byKey(const ValueKey('haptics-device-lab')), findsNothing);
      final off = find.text('Buzz the band');
      expect(off, findsOneWidget);
      expect(isDimmed(t, off), isTrue,
          reason: 'present, dimmed and inert without a link');
      expect(find.text('Connect to the band first'), findsWidgets);
      await openHapticsTab(t, 'patterns');
      expect(find.byKey(const ValueKey('haptics-new-notes')), findsNothing);

      await hub(_caps(devMode: true, connected: true, generation: 'gen5'));
      await openHapticsTab(t, 'band');
      expect(find.byKey(const ValueKey('haptics-device-lab')), findsOneWidget);
      expect(isDimmed(t, find.text('Buzz the band')), isFalse);
      await openHapticsTab(t, 'patterns');
      expect(find.byKey(const ValueKey('haptics-new-notes')), findsOneWidget);
    });
  });

  group('Alarm', () {
    testWidgets('the not-connected card follows alarmBandControls', (t) async {
      await pump(t, const AlarmScreen(), _caps());
      expect(find.text('The band is not connected'), findsOneWidget);
      await pump(t, const AlarmScreen(), _caps(connected: true));
      expect(find.text('The band is not connected'), findsNothing);
    });
    testWidgets('Natural Wake rows follow naturalWake', (t) async {
      await pump(t, const AlarmScreen(), _caps());
      expect(find.text('Natural Wake'), findsWidgets);
      await pump(
          t, const AlarmScreen(), _caps(flagsOff: {FeatureFlag.naturalWake}));
      expect(find.text('Natural Wake'), findsNothing);
    });
  });

  group('Heart Screener', () {
    testWidgets('Take ECG follows ecgTake', (t) async {
      await pump(t, const EcgHomeScreen(), _caps());
      expect(find.text('Take ECG needs a connected WHOOP MG.'), findsOneWidget);
      await pump(
          t, const EcgHomeScreen(), _caps(connected: true, ecgLive: true));
      expect(find.text('WHOOP MG · band-reported'), findsOneWidget);
    });
  });

  group('Health', () {
    testWidgets('the Heart Screener door follows ecgEntry', (t) async {
      const health = HealthScreen(data: HealthData(daysWithData: 2), tab: 0);
      await pump(t, const Scaffold(body: health), _caps());
      expect(find.byType(EcgEntryCard), findsNothing);
      await pump(t, const Scaffold(body: health), _caps(ecgPaired: true));
      expect(find.byType(EcgEntryCard), findsOneWidget);
    });
  });

  group('Breathing', () {
    testWidgets('the beat-timing rows follow breathingBeatTiming', (t) async {
      await pump(t, const CalmBreathing(), _caps());
      expect(
          find.text('Needs the band on. The comparison uses beat timing.'),
          findsNWidgets(2));
      await pump(t, const CalmBreathing(), _caps(connected: true));
      expect(
          find.text('Needs the band on. The comparison uses beat timing.'),
          findsNothing);
    });
  });

  group('Automation', () {
    testWidgets('the Android intent copy follows androidAutomation', (t) async {
      await pump(t, const AutomationSettings(),
          _caps(platform: TargetPlatform.iOS));
      expect(find.textContaining('broadcasts an Android intent'), findsNothing);
      await pump(t, const AutomationSettings(), _caps());
      expect(find.textContaining('broadcasts an Android intent'),
          findsOneWidget);
    });
  });

  group('Source entries (devices)', () {
    test('catalog and priority entries follow the features', () {
      expect(showSourceCatalogEntry(_caps()), isTrue);
      expect(
          showSourceCatalogEntry(_caps(flagsOff: {FeatureFlag.sourceResolverUi})),
          isFalse);
      final off = _caps(flagsOff: {FeatureFlag.sourceResolverUi});
      expect(showSignalPriorityEntry(off, contended: false), isFalse);
      expect(showSignalPriorityEntry(off, contended: true), isTrue,
          reason: 'two devices contending is a data fact, not a capability');
      expect(showSignalPriorityEntry(_caps(), contended: false), isTrue);
    });
  });

  group('Community nudge', () {
    testWidgets('developer mode comes from Capabilities and skips dismissal',
        (t) async {
      for (final k in ['nudge.discord.dismissed', 'nudge.donate.dismissed']) {
        Prefs.setBool(k, true);
        addTearDown(() => Prefs.setBool(k, false));
      }
      await pump(t, const Scaffold(body: CommunityNudge()), _caps(),
          ready: find.byType(CommunityNudge));
      expect(find.text('Join Discord'), findsNothing);
      await pump(t, const Scaffold(body: CommunityNudge()),
          _caps(devMode: true));
      expect(find.text('Join Discord'), findsOneWidget);
    });
  });
}
