// No Profile landing screen. Whatever opened
// Profile home opens Settings (MoreSettings) directly; Quick access is gone;
// Community (GitHub, Reddit, Discord, Sponsor) is an accordion in Settings;
// everything else keeps its grouping; depths shrink by one.
// It was later reordered: "You & preferences" first, Community directly
// above Connections, and "Band" is called "Hardware" (same persisted id).
//
// What lived only on Profile home today (checked against ProfileHomeView):
//  - Quick access > My devices      -> Settings > Hardware > My devices (exists)
//  - Quick access > Settings        -> obsolete (this IS Settings now)
//  - Community x4                   -> Settings > Community (new)
//  - the "N sources" sub-line under My devices (profileSourcesCount) has no
//    twin; the My devices screen itself lists the sources. Not asserted.
//  - ProfileStats.name is loaded but never drawn: nothing to preserve.
//
// This file deliberately never names ProfileHome / ProfileHomeView /
// ProfileStats, so it still compiles once they are deleted.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show screenForRoute;
import 'package:openstrap_edge/notify/tap_router.dart' show kRouteProfile;
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

import 'support/dart_source_lexical.dart';
import 'support/settings_sections.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: LocaleController.seed(null),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

List<String> _rowTitles(WidgetTester t, String sectionTitle) => t
    .widgetList<SetRow>(
        find.descendant(of: section(sectionTitle), matching: find.byType(SetRow)))
    .map((r) => r.title)
    .toList();

class _Pushes extends NavigatorObserver {
  int depth = 0;
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) {
      depth++;
      pushed.add(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;
}

const _groups = [
  'You & preferences',
  'Hardware',
  'Alerts',
  'Data & privacy',
  'Community',
  'Connections',
  'About',
];

List<List<String>> _tableRows(String md) {
  final lines = md.split('\n').where((l) => l.trim().startsWith('|')).toList();
  return [
    for (final l in lines)
      l
          .trim()
          .substring(1, l.trim().length - 1)
          .split('|')
          .map((c) => c.trim())
          .toList(),
  ];
}

void main() {
  group('Profile entry opens Settings directly', () {
    test('the /profile route (battery notification, deep link) is Settings',
        () {
      final w = screenForRoute(kRouteProfile);
      expect(w, isNotNull);
      expect(w.runtimeType.toString(), 'MoreSettings',
          reason: 'no landing screen in between');
    });

    testWidgets('openProfile() pushes Settings, not a landing screen',
        (t) async {
      final pushes = _Pushes();
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(
        navigatorObservers: [pushes],
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      // Only inspect what was pushed: building MoreSettings needs AppState.
      openProfile(ctx);
      expect(pushes.pushed, hasLength(1));
      final route = pushes.pushed.single as MaterialPageRoute<void>;
      expect(route.builder(ctx).runtimeType.toString(), 'MoreSettings');
    });

    test("Home's Profile button opens Settings", () {
      final src = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(code, isNot(contains('ProfileHome')),
          reason: 'Home no longer opens a Profile landing screen');
      expect(code.contains('MoreSettings()') || code.contains('openProfile('),
          isTrue,
          reason: 'the Profile button opens Settings (directly, or through '
              'openProfile, which does)');
    });

    testWidgets('Settings has no Quick access area', (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: true));
      expect(find.text('Quick access'), findsNothing);
    });
  });

  group('Community sits directly above Connections in Settings', () {
    testWidgets('group order: Community sits above Connections',
        (t) async {
      await _pump(t, const MoreSettingsView(version: '1'));
      expect(sectionTitles(t), _groups);
    });

    testWidgets('with dev mode on, Developer is still last', (t) async {
      await _pump(t, const MoreSettingsView(devMode: true, version: '1'));
      expect(sectionTitles(t), [..._groups, 'Developer']);
    });

    testWidgets('Community rows: GitHub, Reddit, Discord, Sponsor, in order',
        (t) async {
      await _pump(t, const MoreSettingsView());
      expect(_rowTitles(t, 'Community'),
          ['GitHub', 'Reddit', 'Discord', 'Sponsor']);
      for (final r in t.widgetList<SetRow>(find.descendant(
          of: section('Community'), matching: find.byType(SetRow)))) {
        expect(r.onTap, isNotNull, reason: '${r.title} opens its link');
      }
    });

    testWidgets('Community starts expanded, below Hardware, above Connections',
        (t) async {
      await _pump(t, const MoreSettingsView());
      final community = accordions(t).singleWhere((a) => a.title == 'Community');
      expect(
          find.descendant(
              of: section('Community'),
              matching: find.byWidget(community.children.first)),
          findsOneWidget);
      expect(t.getTopLeft(find.text('Hardware')).dy,
          lessThan(t.getTopLeft(find.text('Community')).dy));
      expect(t.getTopLeft(find.text('Community')).dy,
          lessThan(t.getTopLeft(find.text('Connections')).dy));
    });

    testWidgets('each Profile-only item exists exactly once on Settings',
        (t) async {
      await _pump(t, const MoreSettingsView(relaySupported: true));
      for (final title in const [
        'GitHub',
        'Reddit',
        'Discord',
        'Sponsor',
        'My devices',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(
          find.descendant(
              of: section('Hardware'), matching: find.text('My devices')),
          findsOneWidget,
          reason: 'My devices keeps its home, now called Hardware');
    });
  });

  group('every setting is still reachable, one push shallower', () {
    // Settings is now the landing, so every row is ONE push from it.
    late GlobalKey<NavigatorState> nav;
    late _Pushes pushes;

    void push(String name) => nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: Center(child: Text('DEST:$name')))));

    Future<void> pumpRoot(WidgetTester t) async {
      nav = GlobalKey<NavigatorState>();
      pushes = _Pushes();
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
            devMode: true,
            onAlarm: () => push('Alarm'),
            onBandNotifications: () => push('App notifications on the band'),
            onDevices: () => push('My devices'),
            onHaptics: () => push('Haptics'),
            onEditProfile: () => push('Edit profile'),
            onCoach: () => push('AI coach'),
            onLiveDevices: () => push('Live devices'),
            onDeviceLab: () => push('Device lab'),
            onGestures: () => push('Gestures'),
            onNotifications: () => push('Notifications'),
            onData: () => push('Data'),
            onAutomation: () => push('Automation'),
            onEditSleepSchedule: () => push('Expected sleep schedule'),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    for (final (row, dest) in [
      ('My devices', 'My devices'),
      ('Alarm', 'Alarm'),
      ('Gestures', 'Gestures'),
      ('Haptics', 'Haptics'),
      ('Alerts and notifications', 'Notifications'),
      ('App notifications on the band', 'App notifications on the band'),
      ('Export, backup, import', 'Data'),
      ('Tasker and Shortcuts', 'Automation'),
      ('Expected sleep schedule', 'Expected sleep schedule'),
      ('Edit profile', 'Edit profile'),
      ('AI coach', 'AI coach'),
      ('Live devices', 'Live devices'),
      ('Device lab', 'Device lab'),
    ]) {
      testWidgets('$dest is one push from the Settings landing', (t) async {
        await pumpRoot(t);
        await t.tap(find.text(row).last);
        await t.pumpAndSettle();
        expect(find.text('DEST:$dest'), findsOneWidget);
        expect(pushes.depth, 1);
      });
    }
  });

  group('docs/navigation-depth.md: depths shrink by one', () {
    // After the change every path starts at Settings (the landing), not at a
    // Profile home that no longer exists. Arrows = pushes.
    const expected = {
      'Settings': 0,
      'Alerts and notifications': 1,
      'App notifications on the band': 1,
      'Gestures': 1,
      'Haptics': 1,
      'Alarm': 1,
      'Automation': 1,
      'Data': 1,
      'Expected sleep schedule': 1,
      'Device detail': 2,
      'Device lab': 1,
      'Edit profile': 1,
      'Live devices': 1,
      'AI coach': 1,
      'Language': 1,
      'Storage': 0,
    };

    test('the After column starts at Settings and is one push shallower', () {
      final rows = _tableRows(File('docs/navigation-depth.md').readAsStringSync());
      final header = rows.first;
      final screen = header.indexOf('Screen');
      final after = header.indexOf('After');
      final body = rows
          .skip(1)
          .where((r) => !r.every((c) => RegExp(r'^:?-+:?$').hasMatch(c)));
      final seen = <String>{};
      for (final r in body) {
        seen.add(r[screen]);
        expect(r[after], startsWith('Settings'),
            reason: '${r[screen]}: no Profile home to start from any more');
        expect(r[after], isNot(contains('Profile')), reason: r[screen]);
        final want = expected[r[screen]];
        if (want != null) {
          expect('→'.allMatches(r[after]).length, want,
              reason: '${r[screen]}: ${r[after]}');
        }
      }
      expect(seen, containsAll(expected.keys));
    });

    test('the prose no longer promises a Quick access area on Profile home',
        () {
      final md = File('docs/navigation-depth.md').readAsStringSync();
      expect(md, isNot(contains('Profile home keeps two Quick access rows')));
      expect(md, contains('Community'),
          reason: 'the doc records Community as the first Settings group');
    });
  });
}
