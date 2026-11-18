// why: kept pilots must be identifiable at every entry point, without shrinking
// the controls. Catches a missing badge or a label that replaces the tap target.
// CLAIM(pilot-entry-labels).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget child, {String locale = 'en'}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(360, 2400);
  addTearDown(t.view.reset);
  final controller = LocaleController.seed(locale);
  addTearDown(controller.dispose);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: controller,
    child: MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: child,
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Finder _pilotIn(Finder entry, String label) => find.descendant(
  of: entry, matching: find.widgetWithText(Pill, label));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    // Match the chart fixtures so AM/PM axis layout cannot mask the entry check.
    final clock = ClockFormatController.seed(ClockFormat.h24);
    addTearDown(clock.dispose);
  });
  tearDown(ClockFormatController.debugReset);

  testWidgets('Settings Tracks entry carries Pilot and retains its target', (t) async {
    await _pump(t, const MoreSettingsView());
    final entry = find.widgetWithText(SetRow, 'Tracks');
    expect(_pilotIn(entry, 'Pilot'), findsOneWidget);
    expect(t.getSize(entry).height, greaterThanOrEqualTo(48));
    expect(t.widget<SetRow>(entry).onTap, isNotNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('Typical day Tracks entry carries Pilot and retains its target', (t) async {
    await _pump(t, const TypicalDayScreen(data: TypicalDayData()));
    final entry = find.widgetWithText(TextButton, 'Tracks');
    expect(_pilotIn(entry, 'Pilot'), findsOneWidget);
    expect(t.getSize(entry).height, greaterThanOrEqualTo(48));
    expect(t.widget<TextButton>(entry).onPressed, isNotNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('Home and journal shared track logger identifies the pilot', (t) async {
    await _pump(t, const Scaffold(body: TrackQuickLog()));
    final entry = find.byKey(const ValueKey('track-quick-log'));
    expect(_pilotIn(entry, 'Pilot'), findsOneWidget);
    expect(t.getSize(entry).height, greaterThanOrEqualTo(48));
    expect(t.takeException(), isNull);
  });

  const labels = {
    'en': 'Pilot', 'de': 'Pilot', 'es': 'Piloto', 'fr': 'Pilote',
    'hi': 'प्रायोगिक', 'ru': 'Пилот', 'th': 'ทดลอง', 'zh': '试验版',
  };
  for (final entry in labels.entries) {
    testWidgets('${entry.key}: Motion entry labels the pilot before opening it', (t) async {
      await _pump(t, const DeviceLabView(
        tapTools: false, motion: SizedBox(key: ValueKey('motion-content')),
        initialTab: LabTab.logs,
      ), locale: entry.key);
      final motion = find.byKey(const ValueKey('device-lab-tab:motion'));
      expect(_pilotIn(motion, entry.value), findsOneWidget);
      expect(t.getSize(motion).height, greaterThanOrEqualTo(48));
      await t.tap(motion);
      await t.pump();
      expect(find.byKey(const ValueKey('motion-content')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
