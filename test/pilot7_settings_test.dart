import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/home_header.dart';
import 'package:openstrap_edge/ui2/profile/home_header_settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bundled_fonts.dart';
import 'support/home_header_pilot_fakes.dart';
import 'support/pilot_shots.dart';
import 'support/themed_settings_helpers.dart';

class _App extends PilotHeaderApp {
  @override
  Future<bool?> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<bool> hasOemAutostartSettings() async => true;

  @override
  Future<int> dataFileBytes() async => 12 * 1024 * 1024;

  @override
  Future<void> refreshAiReminders() async {}

  @override
  Future<void> refreshPilotAlarms({bool sourceChanged = false}) async {}
}

Future<void> _prefs({bool alarm = true}) async {
  SharedPreferences.setMockInitialValues({
    PilotFlag.homeHeader.key: true,
    PilotFlag.alarmScreen.key: alarm,
    PilotFlag.sleepSummary.key: true,
    PilotFlag.observations.key: true,
    PilotFlag.timelines.key: true,
    PilotFlag.wakeMethods.key: true,
    for (final id in ['settings_band', 'settings_alerts', 'settings_data_privacy',
      'settings_connections', 'settings_community'])
      accordionPrefKey(id): false,
  });
  await Prefs.reload();
}

Widget _settings(_App app, ThemeController theme) => pilotApp(
  app,
  MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: theme),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      ChangeNotifierProvider(create: (_) => ClockFormatController.seed(ClockFormat.h24)),
    ],
    child: pilotShot(const MoreSettings()),
  ),
);

Finder _within(String id, Finder child) =>
    find.descendant(of: accordionById(id), matching: child);

void main() {
  setUpAll(loadFonts);
  setUp(() {
    NotificationService.instance.debugProbePermission = () async => true;
  });
  tearDown(() => NotificationService.instance.debugProbePermission = null);

  // why: Pilot 6 routed Appearance into Header settings whenever the pilot was
  // on. The theme should cycle in place and the two cards retain their rows.
  testWidgets('Appearance cycles while the header pilot is on', (t) async {
    pilotSurface(t);
    await _prefs();
    final app = _App();
    final theme = ThemeController.seed(AppThemeChoice.system, Brightness.dark);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settings(app, theme));
    await t.pumpAndSettle();

    final appearance = _within('settings_preferences', find.text('Appearance'));
    await t.tap(appearance);
    await t.pumpAndSettle();
    expect(theme.choice, AppThemeChoice.light);
    expect(find.byType(HomeHeaderAppearance), findsNothing);
    await t.tap(appearance);
    await t.pumpAndSettle();
    expect(theme.choice, AppThemeChoice.dark);
    await t.tap(appearance);
    await t.pumpAndSettle();
    expect(theme.choice, AppThemeChoice.system);
    expect(find.text('Pull down to sync'), findsNothing);
    expect(find.text('Zoom wake-up events'), findsNothing);
    await takePilotShot(t, 'settings-top-build');

    final behaviour = accordionById('settings_app_behaviour');
    await t.scrollUntilVisible(behaviour, 250);
    await t.pumpAndSettle();
    await takePilotShot(t, 'settings-behaviour-build');
    for (final title in ['Settings as tab', 'Units', 'Time format', 'Allow auto-start', 'Calculations']) {
      expect(_within('settings_app_behaviour', find.text(title)), findsOneWidget);
    }
    expect(_within('settings_preferences', find.text('Units')), findsNothing);
    expect(t.takeException(), isNull);
  });

  // why: a pilot toggle owns its options. The alarm switch changes the
  // persisted rule, and its title still opens the destination controls.
  testWidgets('Labs nests header style and alarm notices under their switches', (t) async {
    pilotSurface(t);
    await _prefs();
    final app = _App();
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settings(app, theme));
    await t.pumpAndSettle();

    final labs = accordionById('settings_labs');
    await t.scrollUntilVisible(labs, 300);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Labs').first);
    await t.pumpAndSettle();
    final header = find.byKey(ValueKey(PilotFlag.homeHeader.key));
    final alarm = find.byKey(ValueKey(PilotFlag.alarmScreen.key));
    final style = _within('settings_labs', find.text('Style'));
    final latch = _within('settings_labs', find.text('Alarm not confirmed'));
    expect(t.getTopLeft(header).dy, lessThan(t.getTopLeft(style).dy));
    expect(t.getTopLeft(style).dy, lessThan(t.getTopLeft(alarm).dy));
    expect(t.getTopLeft(alarm).dy, lessThan(t.getTopLeft(latch).dy));
    await takePilotShot(t, 'settings-labs-build');

    await t.tap(find.text('Compact'));
    await t.pumpAndSettle();
    expect(HomeHeader.compact, isTrue);
    await t.tap(find.text('How Compact works'));
    await t.pumpAndSettle();
    expect(find.byType(HomeHeaderAppearance), findsOneWidget);
    expect(find.textContaining('Long press', findRichText: true), findsOneWidget);
    Navigator.of(t.element(find.byType(HomeHeaderAppearance))).pop();
    await t.pumpAndSettle();

    final checkIn = find.byKey(const ValueKey('labs-alarm-notice:alarmNightCheck'));
    await t.ensureVisible(checkIn);
    await t.pumpAndSettle();
    expect(t.widget<Switch>(checkIn).value, isTrue);
    await t.tap(checkIn);
    await t.pumpAndSettle();
    expect(t.widget<Switch>(checkIn).value, isFalse);
    expect((await NotificationPrefs.load()).alarmNightCheckEnabled, isFalse);
    expect((await NotificationPrefs.load()).alarmLatchFailedEnabled, isTrue);

    await t.ensureVisible(latch);
    await t.pumpAndSettle();
    await t.tap(latch);
    await t.pumpAndSettle();
    expect(find.byType(NotificationSettings), findsOneWidget);
    expect(find.text('Phone + Band'), findsOneWidget);
    Navigator.of(t.element(find.byType(NotificationSettings))).pop();
    await t.pumpAndSettle();

    await t.ensureVisible(alarm);
    await t.pumpAndSettle();
    await t.tap(alarm);
    await t.pumpAndSettle();
    expect(latch, findsNothing);
    expect(style, findsOneWidget);
    await t.ensureVisible(header);
    await t.pumpAndSettle();
    await t.tap(header);
    await t.pumpAndSettle();
    expect(style, findsNothing);
  });
}
