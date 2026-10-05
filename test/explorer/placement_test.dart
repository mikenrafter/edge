// 8AH. Where the Explorer lives: NOT in Health.
//
// DECISION (reversed after a first try as a fifth Health tab): the Data
// Explorer is not ready for everyone, so Health keeps its four sub-tabs (Last
// night, Today, Trends, Labs) and the Explorer is reached from Settings >
// Developer > "Data Explorer", developer mode only. It opens full screen,
// under a NavBar titled "Data Explorer".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show goto;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

import 'support.dart';

const _four = ['Last night', 'Today', 'Trends', 'Labs'];

Future<void> _health(WidgetTester t, int tab,
    {double width = 360, double scale = 1}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 4000);
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = ExplorerRepo();
  addTearDown(app.dispose);
  await t.pumpWidget(providers(
    app,
    HealthScreen(
      data: const HealthData(),
      vitals: const VitalsData(),
      explore: const ExploreData(),
      labs: const LabsData(markers: kLabMarkers),
      tab: tab,
    ),
    scale: scale,
  ));
  await settle(t);
}

SubTabs _tabs(WidgetTester t) => t.widget<SubTabs>(find.byType(SubTabs).first);

/// Settings' view, with the Data Explorer row pushing the real screen the way
/// MoreSettings does.
Future<void> _settings(WidgetTester t, {required bool dev}) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = ExplorerRepo();
  addTearDown(app.dispose);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (c) => MoreSettingsView(
          devMode: dev,
          onDataExplorer: () => goto(c, const ExplorerScreen()),
        ),
      ),
    ),
  ));
  await settle(t);
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('Health has four sub-tabs again', () {
    testWidgets('the tabs are Last night, Today, Trends, Labs; not dense',
        (t) async {
      await _health(t, 0);
      expect(_tabs(t).items, _four);
      expect(_tabs(t).dense, isFalse);
      expect(find.text('Explore'), findsNothing);
      expect(find.byType(ExplorerView), findsNothing);
    });

    testWidgets('Labs is tab 3 and the Explorer is nowhere in Health', (t) async {
      await _health(t, 3);
      expect(_tabs(t).index, 3);
      expect(find.text('Add a result'), findsOneWidget);
      expect(find.byType(ExplorerView), findsNothing);
      await t.pumpWidget(const SizedBox());
      await _health(t, 2);
      expect(find.byType(ExplorerView), findsNothing);
      expect(find.byKey(const ValueKey('explore-scale:daily')), findsNothing);
    });

    test('an old five-tab index still lands on the right one of the four', () {
      expect(HealthScreen.tabFromLegacy(4), 3);
      expect(HealthScreen.tabFromLegacy(3), 1);
    });
  });

  group('Settings > Developer > Data Explorer', () {
    testWidgets('is there in developer mode', (t) async {
      await _settings(t, dev: true);
      expect(find.text('Data Explorer'), findsOneWidget);
    });

    testWidgets('is not there without developer mode', (t) async {
      await _settings(t, dev: false);
      expect(find.text('Data Explorer'), findsNothing);
    });

    testWidgets('opens the Explorer full screen under a NavBar of that name',
        (t) async {
      await _settings(t, dev: true);
      await t.tap(find.text('Data Explorer'));
      await settle(t);
      expect(find.byType(ExplorerScreen), findsOneWidget);
      expect(find.byType(ExplorerView), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(NavBar), matching: find.text('Data Explorer')),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('MoreSettings wires the row to ExplorerScreen', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      expect(src,
          contains('onDataExplorer: () => goto(c, const ExplorerScreen())'));
    });
  });

  group('one catalogue', () {
    test('kMetricCatalogue is the whole Trends list, moved not rewritten', () {
      final keys = [
        for (final c in kMetricCatalogue)
          for (final r in c.rows) r.key,
      ];
      expect(keys.toSet().length, keys.length, reason: 'no duplicate row');
      expect(keys.toSet(), {
        'readiness', 'stress', 'resting_hr', 'hrv', 'hrv_cv', 'lf_hf', 'dip',
        'hrr', 'sleep', 'efficiency', 'deep', 'rem', 'nap_min', 'resp_rate',
        'brv', 'steps', 'active_min', 'calories', 'strain', 'trimp',
        'skin_temp', 'wear',
      });
      final series = {
        for (final c in kMetricCatalogue)
          for (final r in c.rows) r.key: r.series,
      };
      expect(series['hrv'], 'rmssd');
      expect(series['resting_hr'], 'rhr');
      expect(series['sleep'], 'tst_min');
      expect([for (final c in kMetricCatalogue) c.title].first, 'Recovery');
    });

    test('health_screen.dart no longer declares its own copy', () {
      final health = File('lib/ui2/screens/health_screen.dart').readAsStringSync();
      expect(health, isNot(contains('const _catalogue')));
      expect(health, contains('kMetricCatalogue'));
    });

    test('explorer.dart reads the shared list and keeps no list of its own', () {
      final src = File('lib/ui2/screens/explorer.dart').readAsStringSync();
      expect(src, contains('kMetricCatalogue'));
      expect(src, isNot(contains(RegExp(r'(?<![A-Za-z])_catalogue\b'))));
      expect(src, isNot(contains("'lf_hf'")),
          reason: 'catalogue keys are not re-listed in the Explorer');
    });
  });
}
