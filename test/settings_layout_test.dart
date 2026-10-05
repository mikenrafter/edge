// 8AI G2 (red first): the Settings landing screen's layout.
//
// ASSUMED BEHAVIOUR (MoreSettingsView, lib/ui2/profile/settings.dart; no new
// public symbol is needed, so every failure below is an assertion):
//
//  1. The phone-steps row is GONE from Settings. Its title today is the
//     English fallback "Steps" (l10n settingsStepsRowTitle) with the On/Off
//     value; the spec calls it "Count steps from this phone". Neither
//     spelling may appear on Settings. The switch stays ONLY on My devices
//     (devices.dart, the phone's row), bound to the same AppState preference:
//     settings.dart no longer reads or toggles phone steps at all.
//  2. The "Band" accordion is titled "Hardware". Its persisted accordion id
//     stays `settings_band` (CHOICE: keep the id rather than migrate, so a
//     person who folded it keeps it folded, and no migration code exists to go
//     wrong). Its rows are unchanged: My devices, Gestures, Haptics.
//  3. Accordion order, dev mode off:
//       You & preferences, Hardware, Alerts, Data & privacy, Community,
//       Connections, About            (+ Developer last in dev mode)
//     i.e. "You & preferences" first, today's order otherwise, Community moved
//     down to sit directly ABOVE Connections.
//  4. "Look barcodes up online" (the spec writes "Look up barcodes online";
//     either spelling passes) moves out of Data & privacy into Connections.
//     There is no group called "Integrations" anywhere in the app (grep of
//     lib/ and docs/ finds none): Connections is the group that holds the
//     integrations (AI coach, Tasker and Shortcuts, update checks), so the row
//     goes there. Position inside Connections is free.
//  5. Every other row keeps its title and its order inside its group.
//
// Existing tests this change makes stale, to update at implementation time (not
// edited here): test/settings_regroup_test.dart (`_groups`, `_rows`,
// "Community first", "Band" rows, "Steps and Units live in...", barcode row in
// Data & privacy), test/settings_landing_test.dart (`_groups`, "Community
// is the first accordion"), test/alarm_in_alerts_test.dart (section
// 'Band', and the source index of "SettingsAccordion('Band'"),
// test/settings_sections_test.dart:57, test/haptics/
// haptics_settings_test.dart:180 (section('Band')),
// test/settings_accordion_state_test.dart (Settings > 'Band'),
// test/device_phone_always_listed_test.dart ('one preference, two doors' drives the
// Settings Steps row), docs/navigation-depth.md (group order sentence).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/platform/app_icon.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/themed_settings_helpers.dart';

Widget _settings({bool dev = false}) => MoreSettingsView(
      devMode: dev,
      relaySupported: true,
      version: '0.9.99 (1)',
      appIcon: AppIconChoice.colourful,
      showHealthShare: true,
      showUpdateChecks: true,
    );

Future<void> _pump(WidgetTester t, Widget w) async {
  g123View(t, height: 30000);
  await t.pumpWidget(g123App(w));
  await g123Settle(t);
}

List<String> _titles(WidgetTester t) => [
      for (final a in t.widgetList<SettingsAccordion>(
          find.byType(SettingsAccordion)))
        a.title,
    ];

Finder _section(String title) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.title == title,
    description: 'SettingsAccordion "$title"');

/// The titles of the [SetRow]s inside one accordion, top to bottom.
List<String> _rows(WidgetTester t, String section) => [
      for (final r in t.widgetList<SetRow>(find.descendant(
          of: _section(section), matching: find.byType(SetRow))))
        r.title,
    ];

const _barcode = ['Look barcodes up online', 'Look up barcodes online'];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('order and names', () {
    testWidgets('You & preferences first, Community directly above '
        'Connections, Band is called Hardware', (t) async {
      await _pump(t, _settings());
      expect(_titles(t), [
        'You & preferences',
        'Hardware',
        'Alerts',
        'Data & privacy',
        'Community',
        'Connections',
        'About',
      ]);
    });

    testWidgets('dev mode: Developer is still last', (t) async {
      await _pump(t, _settings(dev: true));
      expect(_titles(t).last, 'Developer');
      expect(_titles(t).first, 'You & preferences');
    });

    testWidgets('on screen, top to bottom, in that order', (t) async {
      await _pump(t, _settings());
      expect(_titles(t).first, 'You & preferences');
      expect(
          t.getTopLeft(_section('Community')).dy,
          lessThan(t.getTopLeft(_section('Connections')).dy));
      expect(
          t.getTopLeft(_section('Data & privacy')).dy,
          lessThan(t.getTopLeft(_section('Community')).dy),
          reason: 'Community sits below Data & privacy now');
      final ys = [
        for (final s in _titles(t)) t.getTopLeft(_section(s)).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: _titles(t)[i]);
      }
    });

    testWidgets('no accordion is still titled "Band"', (t) async {
      await _pump(t, _settings(dev: true));
      expect(_titles(t), isNot(contains('Band')));
      expect(find.text('Band'), findsNothing,
          reason: 'the visible title is Hardware');
    });

    testWidgets('Hardware keeps its rows and the persisted id settings_band',
        (t) async {
      await _pump(t, _settings());
      expect(_rows(t, 'Hardware'),
          ['My devices', 'Gestures', 'Haptics', 'Gesture failures']);
      expect(t.widget<SettingsAccordion>(_section('Hardware')).id,
          'settings_band',
          reason: 'remembered fold state survives the rename (no migration)');
    });

    testWidgets('a section folded as "Band" last week is folded as '
        '"Hardware" now, and its neighbours are untouched', (t) async {
      SharedPreferences.setMockInitialValues(
          {accordionPrefKey('settings_band'): false});
      await _pump(t, _settings());
      final open = openStates(t);
      expect(open['settings_band'], isFalse);
      expect(open.entries.where((e) => !e.value).map((e) => e.key),
          ['settings_band']);
    });

    testWidgets('the remembered answers still map to the right sections after '
        'the reorder', (t) async {
      SharedPreferences.setMockInitialValues({
        accordionPrefKey('settings_community'): false,
        accordionPrefKey('settings_preferences'): false,
      });
      await _pump(t, _settings());
      final open = openStates(t);
      expect(open['settings_community'], isFalse);
      expect(open['settings_preferences'], isFalse);
      expect(open.entries.where((e) => !e.value).map((e) => e.key).toSet(),
          {'settings_community', 'settings_preferences'});
    });
  });

  group('rows', () {
    testWidgets('You & preferences: no steps row, the rest unchanged',
        (t) async {
      await _pump(t, _settings());
      final rows = _rows(t, 'You & preferences');
      expect(rows, [
        'Edit profile',
        'Language',
        'Units',
        'Appearance',
        'Pull down to sync',
        'Expected sleep schedule',
        'Cycle tracking',
      ], reason: 'the icon picker is not a SetRow; Steps is gone');
    });

    testWidgets('Settings has no phone-steps row under any name', (t) async {
      await _pump(t, _settings(dev: true));
      for (final title in const [
        'Steps',
        'Steps from this phone',
        'Count steps from this phone',
      ]) {
        expect(find.text(title), findsNothing, reason: title);
      }
    });

    testWidgets('Data & privacy: the barcode row is gone', (t) async {
      await _pump(t, _settings());
      expect(_rows(t, 'Data & privacy'), [
        'Storage',
        'Export, backup, import',
        'Calculations', // P5: the power mode (see test/p5)
        'Write to Apple Health',
        'Contribute my health data',
        'Crash reports',
      ]);
    });

    testWidgets('Connections holds the barcode lookup, and the old three in '
        'order', (t) async {
      await _pump(t, _settings());
      final rows = _rows(t, 'Connections');
      expect(rows.where(_barcode.contains), hasLength(1),
          reason: 'exactly one barcode row, inside Connections: $rows');
      final others = rows.where((r) => !_barcode.contains(r)).toList();
      expect(others, ['AI coach', 'Tasker and Shortcuts', 'Check for updates']);
      expect(find.text(_barcode.first), findsOneWidget,
          reason: 'one door only');
    });

    testWidgets('Community, Alerts, About keep their rows', (t) async {
      await _pump(t, _settings());
      expect(_rows(t, 'Community'), ['GitHub', 'Reddit', 'Discord', 'Sponsor']);
      expect(_rows(t, 'Alerts'), [
        'Alarm',
        'Alerts and notifications',
        'App notifications on the band',
      ]);
      expect(_rows(t, 'About'), ['Version', 'Notices and licences']);
    });
  });

  group('one source of truth for phone steps', () {
    testWidgets('the phone row on My devices still carries the toggle',
        (t) async {
      var flips = 0;
      g123View(t, height: 2000);
      await t.pumpWidget(g123App(MyDevicesView(
        sources: const [
          HealthSource(
            name: 'This phone',
            kind: 'Motion coprocessor',
            tier: SourceTier.phone,
            icon: Icons.smartphone,
          ),
        ],
        onTogglePhoneSteps: () => flips++,
        phoneStepsOn: true,
      )));
      await t.pump();
      expect(find.text('Count steps from this phone'), findsOneWidget);
      await t.tap(find.byType(Switch));
      expect(flips, 1);
    });
  });
}
