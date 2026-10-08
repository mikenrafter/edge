// Every accordion heading of the Haptics screen is localized, not only
// "General": in a language other than English no English heading remains
// (Tasker is a product name and stays as it is).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/haptics_screen_support.dart';
import 'support/settings_sections.dart';

const _english = {
  'Your patterns',
  'General',
  'Alerts',
  'Apps and automation',
  'Activity',
  'Gestures',
  'Breathing',
  'Alarm snooze',
  'ECG',
  'Safety',
  'Test',
  'Calibration',
};

// A built-in of every section, so every group on the Patterns tab is shown.
List<SavedHapticPattern> _all() => [
      for (final k in [...builtInKeys(), 'alert.health', 'alert.zone', 'alert.relay'])
        SavedHapticPattern(
          id: systemPatternId(k),
          name: builtInDefault(k)!.name,
          sequence: builtInDefault(k)!.sequence,
          systemKey: k,
        ),
    ];

Future<void> _pump(WidgetTester t, Locale locale) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: hubView(HubCalls(), patterns: _all(), profile: kMg, devMode: true),
  ));
  await t.pumpAndSettle();
}

void main() {
  for (final code in const ['zh', 'hi']) {
    testWidgets('$code: no accordion heading is left in English', (t) async {
      await _pump(t, Locale(code));
      final arb = jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
          as Map<String, dynamic>;
      final shown = <String>[];
      for (final tab in const ['patterns', 'alerts', 'activity', 'cues', 'band']) {
        await openHapticsTab(t, tab);
        shown.addAll(sectionTitles(t));
      }
      expect(shown, isNotEmpty);
      for (final title in shown) {
        expect(_english, isNot(contains(title)),
            reason: '"$title" is English in $code');
      }
      // And they are the translations, in the order the tabs list them.
      expect(shown, containsAll([
        for (final k in const [
          'hapticsYourPatterns',
          'hapticsPresetsGeneral',
          'hapticsSectionAlerts',
          'hapticsSectionApps',
          'hapticsSectionActivity',
          'hapticsSectionGestures',
          'hapticsSectionBreathing',
          'hapticsSectionAlarm',
          'hapticsSectionEcg',
          'hapticsSafety',
          'hapticsTest',
          'hapticsCalibration',
        ])
          arb[k],
      ]));
    });
  }

  testWidgets('English is unchanged', (t) async {
    await _pump(t, const Locale('en'));
    final shown = <String>[];
    for (final tab in const ['patterns', 'alerts', 'activity', 'cues', 'band']) {
      await openHapticsTab(t, tab);
      shown.addAll(sectionTitles(t));
    }
    expect(shown.toSet(), {..._english, 'Tasker'});
    // On its own tab Activity is a card, not an accordion.
    await openHapticsTab(t, 'activity');
    expect(sectionTitles(t), isEmpty);
  });
}
