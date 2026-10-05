// 8AE sections A and B (red first): Settings is regrouped by task, the rows
// that used to sit on Profile moved into it (one door each), Device lab sits
// behind dev mode, and the Gestures screen lost its two tuning controls.
//
// Pumped headless as the pure views, like settings_sections_test.dart.
//
// Contracts these tests pin that the spec leaves open:
//  - Row titles are the English fallbacks: "GitHub", "Reddit", "Discord",
//    "Sponsor" (Community; first group in 8AF.7, directly above Connections
//    since 8AI G2); "My devices", "Gestures", "Haptics" (Hardware, called
//    "Band" until 8AI G2; the HR zone alert and its Target zone moved
//    to Alerts in 8AF.6, see zone_alert_test.dart); "Alarm" (moved from Band to
//    the first row of Alerts in 8AF.7), "Alerts and
//    notifications" and "App notifications on the band" (Alerts); "Edit
//    profile", "Language", "Units", "Appearance", "Expected sleep schedule",
//    "Icon", "Cycle tracking" (You & preferences, the first group since 8AI
//    G2; the "Steps" row is gone, phone steps live only in My devices);
//    "Storage", "Export, backup, import", "Write to Apple Health", "Contribute
//    my health data", "Crash reports" (Data & privacy); "AI coach", "Tasker
//    and Shortcuts", "Check for updates", "Look barcodes up online"
//    (Connections, moved from Data & privacy in 8AI G2);
//    "Version", "Notices and licences" (About); "Component gallery", "Live
//    devices", "Device lab", "Developer mode" (Developer).
//  - One title is written loosely in the spec, so either spelling passes: the
//    Tasker row may keep "Tasker and Shortcuts" or be called "Automation".
//  - "My devices" is a Settings > Hardware row. Since 8AF.7 there is no Profile
//    landing screen, so every moved row has exactly one door.
//  - The device-lab push through MoreSettingsView(onDeviceLab:) is in
//    settings_device_lab_entry_test.dart so a missing parameter name fails
//    only that file.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/platform/app_icon.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'support/dart_source.dart';
import 'support/sections.dart';

Widget _app(Widget home) => ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
    );

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w));
  await t.pumpAndSettle();
}

/// Every conditional row switched on, so the full ladder is on screen.
Widget _settings({bool dev = false, bool relay = true}) => MoreSettingsView(
      devMode: dev,
      relaySupported: relay,
      version: '0.9.99 (1)',
      appIcon: AppIconChoice.colourful,
      showHealthShare: true,
      showUpdateChecks: true,
    );

const _groups = [
  'You & preferences',
  'Hardware',
  'Alerts',
  'Data & privacy',
  'Community',
  'Connections',
  'About',
];

// Each row is a list of accepted spellings (usually one).
const Map<String, List<List<String>>> _rows = {
  'Community': [
    ['GitHub'],
    ['Reddit'],
    ['Discord'],
    ['Sponsor'],
  ],
  'Hardware': [
    ['My devices'],
    ['Gestures'],
    ['Haptics'],
    ['Gesture failures'],
  ],
  'Alerts': [
    ['Alarm'],
    ['Alerts and notifications'],
    ['App notifications on the band'],
  ],
  'You & preferences': [
    ['Edit profile'],
    ['Language'],
    ['Units'],
    ['Appearance'],
    ['Pull down to sync'],
    ['Expected sleep schedule'],
    ['Icon'],
    ['Cycle tracking'],
  ],
  'Data & privacy': [
    ['Storage'],
    ['Export, backup, import'],
    ['Write to Apple Health'],
    ['Contribute my health data'],
    ['Crash reports'],
  ],
  'Connections': [
    ['AI coach'],
    ['Tasker and Shortcuts', 'Automation'],
    ['Check for updates'],
    ['Look barcodes up online'],
  ],
  'About': [
    ['Version'],
    ['Notices and licences'],
  ],
  'Developer': [
    ['Component gallery'],
    ['Live devices'],
    ['Device lab'],
    // 8AG P1: the read-only timing line for the last derive pass.
    ['Last calculation'],
    ['Developer mode'],
  ],
};

Finder _in(String sectionTitle, String text) =>
    find.descendant(of: section(sectionTitle), matching: find.text(text));

/// The vertical position of the one row in [sectionTitle] spelled any of
/// [spellings]; fails unless exactly one spelling matches exactly once.
double _rowY(WidgetTester t, String sectionTitle, List<String> spellings) {
  final hits = <Finder>[
    for (final s in spellings)
      if (_in(sectionTitle, s).evaluate().isNotEmpty) _in(sectionTitle, s),
  ];
  expect(hits, hasLength(1),
      reason: '"${spellings.first}" in "$sectionTitle": found '
          '${hits.length} spellings');
  expect(hits.single, findsOneWidget,
      reason: '"${spellings.first}" in "$sectionTitle" appears once');
  return t.getTopLeft(hits.single).dy;
}

void _expectRowsInOrder(WidgetTester t, String sectionTitle) {
  final ys = [
    for (final r in _rows[sectionTitle]!) _rowY(t, sectionTitle, r),
  ];
  for (var i = 1; i < ys.length; i++) {
    expect(ys[i], greaterThan(ys[i - 1]),
        reason: '"$sectionTitle": row ${i + 1} '
            '"${_rows[sectionTitle]![i].first}" is not below row $i '
            '"${_rows[sectionTitle]![i - 1].first}"');
  }
  // No extra rows: every SetRow in the section is one we expected. The
  // app-icon row is not a SetRow, so it is not counted.
  final expectedSetRows = _rows[sectionTitle]!
      .where((r) => !r.contains('Icon'))
      .length;
  expect(
      find
          .descendant(of: section(sectionTitle), matching: find.byType(SetRow))
          .evaluate()
          .length,
      expectedSetRows,
      reason: '"$sectionTitle" has a row the spec does not list');
}

void main() {
  group('Settings top level: groups and order', () {
    testWidgets('dev mode off: the seven groups, You & preferences first, in this order',
        (t) async {
      await _pump(t, _settings());
      expect(sectionTitles(t), _groups);
    });

    testWidgets('dev mode on: Developer is the last group', (t) async {
      await _pump(t, _settings(dev: true));
      expect(sectionTitles(t), [..._groups, 'Developer']);
    });

    testWidgets('every group still starts expanded', (t) async {
      await _pump(t, _settings(dev: true));
      await expectAllSectionsExpanded(t, 'Settings');
    });

    testWidgets('the old group titles are gone', (t) async {
      await _pump(t, _settings(dev: true));
      for (final old in const [
        'The band',
        'This phone',
        'Notifications',
        'Preferences',
        'Your data',
        'Privacy',
        'Automation',
      ]) {
        expect(sectionTitles(t), isNot(contains(old)), reason: old);
      }
    });

    for (final g in _groups) {
      testWidgets('$g: its rows, in order', (t) async {
        await _pump(t, _settings());
        _expectRowsInOrder(t, g);
      });
    }

    testWidgets('Developer: its rows, in order', (t) async {
      await _pump(t, _settings(dev: true));
      _expectRowsInOrder(t, 'Developer');
    });

    testWidgets('Reset all data is not on Settings: it lives in Your data > '
        'Advanced (8AI.2)', (t) async {
      await _pump(t, _settings(dev: true));
      expect(find.text('Reset all data'), findsNothing);
      // Developer, when shown, is the last thing on the page.
      final lastGroup = section('Developer');
      for (final g in _groups) {
        expect(t.getBottomLeft(lastGroup).dy,
            greaterThan(t.getBottomLeft(section(g)).dy),
            reason: g);
      }
    });

    testWidgets('the Notifications row is renamed "Alerts and notifications"',
        (t) async {
      await _pump(t, _settings());
      expect(find.text('Alerts and notifications'), findsOneWidget);
      expect(find.text('Manage notifications'), findsNothing);
    });

    testWidgets(
        'App notifications on the band is Android only: omitted, not disabled',
        (t) async {
      await _pump(t, _settings(relay: false));
      expect(find.text('App notifications on the band'), findsNothing);
      expect(find.text('Band notifications'), findsNothing);
      // The group still exists with its one remaining row.
      expect(sectionTitles(t), _groups);
      expect(_in('Alerts', 'Alerts and notifications'), findsOneWidget);
    });

    testWidgets('the feature is no longer called "Band notifications" here',
        (t) async {
      await _pump(t, _settings());
      expect(find.text('Band notifications'), findsNothing);
    });

    testWidgets('Units live in You & preferences, not elsewhere; phone steps '
        'are not on Settings at all', (t) async {
      await _pump(t, _settings());
      expect(_in('Hardware', 'Units'), findsNothing);
      expect(_in('Alerts', 'Units'), findsNothing);
      expect(find.text('This phone'), findsNothing);
      expect(find.text('Steps'), findsNothing,
          reason: 'My devices is the one door (8AI G2)');
    });

    testWidgets('Contribute my health data is not under a Privacy group',
        (t) async {
      await _pump(t, _settings());
      expect(_in('Data & privacy', 'Contribute my health data'),
          findsOneWidget);
      // Absent when the build does not offer it: conditional, as before.
      await _pump(
          t,
          const MoreSettingsView(
              version: '1', showHealthShare: false, showUpdateChecks: false));
      expect(find.text('Contribute my health data'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
    });
  });

  group('Developer group', () {
    testWidgets('dev mode off: no Developer group and none of its rows',
        (t) async {
      await _pump(t, _settings());
      expect(section('Developer'), findsNothing);
      for (final row in const [
        'Component gallery',
        'Live devices',
        'Device lab',
        'Developer mode',
      ]) {
        expect(find.text(row), findsNothing, reason: row);
      }
    });

    testWidgets('dev mode on: the four rows, each once', (t) async {
      await _pump(t, _settings(dev: true));
      for (final row in const [
        'Component gallery',
        'Live devices',
        'Device lab',
        'Developer mode',
      ]) {
        expect(_in('Developer', row), findsOneWidget, reason: row);
        expect(find.text(row), findsOneWidget, reason: '$row once overall');
      }
    });

    test('the Settings screen opens the lab by pushing DeviceLab', () {
      final code = codeOnly(File('lib/ui2/profile/settings.dart')
          .readAsStringSync());
      expect(code.contains('DeviceLab('), isTrue,
          reason: 'MoreSettings must push the DeviceLab screen');
    });
  });

  group('Settings alone: one door per moved row', () {
    for (final title in const [
      'Edit profile',
      'Language',
      'Storage',
      'AI coach',
      'Live devices',
      'My devices',
      'GitHub',
      'Sponsor',
    ]) {
      testWidgets('"$title" appears exactly once', (t) async {
        await _pump(t, _settings(dev: true));
        expect(find.text(title), findsOneWidget);
      });
    }

    testWidgets('My devices is a Hardware row', (t) async {
      await _pump(t, _settings());
      expect(_in('Hardware', 'My devices'), findsOneWidget);
    });

    testWidgets('there is no Quick access area and no "More settings" row',
        (t) async {
      await _pump(t, _settings(dev: true));
      expect(find.text('Quick access'), findsNothing);
      expect(find.text('More settings'), findsNothing);
      expect(find.text('Your data'), findsNothing);
    });
  });

  group('Device lab: out of the band page', () {
    final band = HealthSource(
      name: 'Synthetic band',
      kind: 'WHOOP 4',
      tier: SourceTier.wristOptical,
      icon: LucideIcons.watch,
      connected: true,
      isBand: true,
      family: 'gen4',
    );

    testWidgets('Tools keeps "Buzz the band" and has no Device lab row',
        (t) async {
      await _pump(t, DeviceDetailView(band, onFind: () {}));
      expect(find.text('Tools'), findsOneWidget);
      expect(_in('Tools', 'Buzz the band'), findsOneWidget);
      expect(find.text('Device lab'), findsNothing);
    });

    test('devices.dart no longer builds a Device lab row or opens the lab',
        () {
      final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
      expect(src.contains("'Device lab'"), isFalse,
          reason: 'no Device lab row on the band page');
      expect(codeOnly(src).contains('DeviceLab('), isFalse,
          reason: 'the band page no longer opens the lab');
    });
  });

  group('Gestures: the duplicated tuning controls are gone', () {
    const supported = {
      DeviceAction.none,
      DeviceAction.markMoment,
      DeviceAction.torch,
    };

    Widget view({bool ecg = true, bool extraTaps = true}) => BandGesturesView(
          chosen: const {},
          supported: supported,
          ecgSupported: ecg,
          repeatWindowMs: 2500,
          onRepeatWindowMs: (_) {},
          onThresholds: (_) {},
          extraTaps: extraTaps,
        );

    for (final ecg in [true, false]) {
      testWidgets('ecgSupported=$ecg: no pause or touch-window controls',
          (t) async {
        await _pump(t, view(ecg: ecg));
        expect(find.text('Pause between double taps'), findsNothing);
        expect(find.text('Touch windows'), findsNothing);
        expect(find.byKey(const ValueKey('repeat-window:+')), findsNothing);
        expect(find.byType(EcgThresholdAdjusters), findsNothing);
      });
    }

    testWidgets('"Count extra taps with" and the count tabs stay',
        (t) async {
      await _pump(t, view());
      expect(section('Count extra taps with'), findsOneWidget);
      expect(find.byKey(const ValueKey('gestures-tab:3')), findsOneWidget);
      expect(find.text('What needs a WHOOP MG'), findsOneWidget);
    });

    testWidgets('both controls remain in the Device lab', (t) async {
      await _pump(
          t,
          DeviceLabView(
              ecgSupported: true,
              repeatWindowMs: 2500,
              onRepeatWindowMs: (_) {},
              onThresholds: (_) {}));
      expect(find.text('Pause between double taps'), findsWidgets);
      expect(find.text('Touch windows'), findsWidgets);
    });
  });

  group('One entrance to the relay screen', () {
    testWidgets('NotificationSettings has no relay group or row', (t) async {
      await _pump(t, const NotificationSettingsView(relaySupported: true));
      expect(find.text('Android Relay'), findsNothing);
      expect(find.text('Buzz on app notifications'), findsNothing);
      expect(find.text('App notifications on the band'), findsNothing);
      expect(find.text('Band notifications'), findsNothing);
      expect(sectionTitles(t), isNot(contains('Android Relay')));
    });

    test('NotificationSettings no longer pushes the relay screen', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final code = codeOnly(src);
      final start = code.indexOf('class NotificationSettingsView');
      final end = code.indexOf('\nclass ', start + 1);
      final body = code.substring(start, end < 0 ? code.length : end);
      expect(body.contains('BandNotifications('), isFalse,
          reason: 'the Settings group is the one entrance');
    });

    testWidgets('the screen and its relay group carry the new name',
        (t) async {
      await _pump(
          t, const BandNotificationsView(enabled: true, granted: true));
      expect(find.text('Band notifications'), findsNothing);
      expect(find.text('Relay'), findsNothing);
      expect(find.text('App notifications on the band'), findsWidgets);
      expect(sectionTitles(t), contains('App notifications on the band'));
    });
  });
}
