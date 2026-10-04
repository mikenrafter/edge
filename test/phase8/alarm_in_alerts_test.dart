// 8AF.7 section D (red first): the Alarm row moves from Settings > Band to
// Settings > Alerts, as the first row of that accordion. Same Settings screen,
// same depth; it is NOT a row inside the Alerts-and-notifications screen. It
// leaves Band entirely (one home).
//
// Pumped headless as the pure view, like settings_regroup_test.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

import 'support/sections.dart';

Widget _app(Widget home, {NavigatorObserver? observer}) =>
    ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        navigatorObservers: [if (observer != null) observer],
        home: home,
      ),
    );

Future<void> _pump(WidgetTester t, Widget w, {NavigatorObserver? observer}) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w, observer: observer));
  await t.pumpAndSettle();
}

List<String> _rowTitles(WidgetTester t, String sectionTitle) => t
    .widgetList<SetRow>(
        find.descendant(of: section(sectionTitle), matching: find.byType(SetRow)))
    .map((r) => r.title)
    .toList();

class _Pushes extends NavigatorObserver {
  int depth = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;
}

void main() {
  group('Settings: Alarm is the first row of Alerts', () {
    testWidgets('Alerts rows, in order: Alarm first', (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: true));
      expect(_rowTitles(t, 'Alerts'), [
        'Alarm',
        'Alerts and notifications',
        'App notifications on the band',
      ]);
    });

    testWidgets('where the relay cannot run, Alarm is still first',
        (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: false));
      expect(_rowTitles(t, 'Alerts'), ['Alarm', 'Alerts and notifications']);
    });

    testWidgets('Alarm is gone from Band, which keeps its other rows',
        (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: true));
      expect(_rowTitles(t, 'Band'), ['My devices', 'Gestures', 'Haptics']);
    });

    testWidgets('one home: Alarm appears exactly once on the screen',
        (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: true, devMode: true));
      expect(find.text('Alarm'), findsOneWidget);
      expect(
          find.descendant(of: section('Alerts'), matching: find.text('Alarm')),
          findsOneWidget);
    });

    testWidgets('the row keeps its sub-line and still opens the alarm',
        (t) async {
      var opened = 0;
      await _pump(
          t, MoreSettingsView(relaySupported: true, onAlarm: () => opened++));
      final row = t.widgetList<SetRow>(find.descendant(
              of: section('Alerts'), matching: find.byType(SetRow))).first;
      expect(row.title, 'Alarm');
      expect(row.sub, "Buzzes on your wrist and runs on the band's clock");
      await t.tap(find.text('Alarm'));
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('same depth: one push from Settings, like every other row',
        (t) async {
      final pushes = _Pushes();
      late GlobalKey<NavigatorState> nav;
      nav = GlobalKey<NavigatorState>();
      t.view.physicalSize = const Size(1170, 30000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
        value: LocaleController.seed(null),
        child: MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [pushes],
          theme: buildTheme(Brightness.light),
          home: MoreSettingsView(
            relaySupported: true,
            onAlarm: () => nav.currentState!.push(MaterialPageRoute<void>(
                builder: (_) =>
                    const Scaffold(body: Center(child: Text('DEST:Alarm'))))),
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Alarm'));
      await t.pumpAndSettle();
      expect(find.text('DEST:Alarm'), findsOneWidget);
      expect(pushes.depth, 1, reason: 'Settings -> Alarm, one push');
    });
  });

  group('Alerts and notifications does not carry it', () {
    testWidgets('no Alarm row or section on the Alerts-and-notifications '
        'screen', (t) async {
      await _pump(t, const NotificationSettingsView(relaySupported: true));
      final titles = t
          .widgetList<SetRow>(find.byType(SetRow))
          .map((r) => r.title)
          .toList();
      expect(titles, isNot(contains('Alarm')),
          reason: 'the Alarm door is a Settings row, not a row in this screen');
      expect(sectionTitles(t), isNot(contains('Alarm')));
    });
  });

  group('structure', () {
    test('in settings.dart the Alarm row is inside the Alerts accordion', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final alerts = src.indexOf("SettingsAccordion('Alerts'");
      final prefs = src.indexOf("SettingsAccordion('You & preferences'");
      final band = src.indexOf("SettingsAccordion('Band'");
      final alarm = src.indexOf('onTap: onAlarm');
      expect(alerts, greaterThan(band));
      expect(alarm, greaterThan(alerts),
          reason: 'the Alarm row sits after the Alerts header');
      expect(alarm, lessThan(prefs),
          reason: 'and before the next group begins');
      expect(src.indexOf('onTap: onAlarm', alarm + 1), -1,
          reason: 'only one Alarm row on the Settings screen');
    });

    test('docs/navigation-depth.md says Alarm lives in Alerts', () {
      final md = File('docs/navigation-depth.md').readAsStringSync();
      final lines = md.split('\n').where((l) => !l.trim().startsWith('|'));
      expect(
          lines.any((l) => l.contains('Alarm') && l.contains('Alerts')), isTrue,
          reason: 'a prose line (outside the table) records the Band -> '
              'Alerts move');
    });
  });
}
