// 8AH, RED. Where the Explorer lives.
//
// DECISION, measured with the real SubTabs at 360 pt (Manrope loaded):
//   Last night | Today | Trends | Explore | Labs
//     default (non-dense) SubTabs : does NOT fit, Labs is off the edge
//     dense: true                 : fits at 1x, right edge ~306 pt, no scrolling
//                                   (at text 1.3x it scrolls ~35 pt, which the
//                                   widget is built to do)
//   So Explore is a FIFTH Health sub-tab, drawn with `dense: true`. There is no
//   "Explore toggle inside Trends".
//
// ASSUMED API:
//   * HealthScreen's sub-tabs become, in order, Last night, Today, Trends,
//     Explore, Labs (indices 0..4) and its SubTabs is `dense`. Tab 3 shows
//     ExplorerView (lib/ui2/screens/explorer.dart); Labs moves to index 4.
//   * lib/ui2/screens/metric_catalogue.dart (and explorer.dart; both exported
//     from screens.dart) exports the Trends catalogue as
//       class MetricCatalogueRow { final String key, series, blurb; }
//       class MetricCategory { final String title; final List<MetricCatalogueRow> rows; }
//       const List<MetricCategory> kMetricCatalogue;
//     health_screen.dart and explorer.dart both read it; neither keeps a copy.
//   * Entering the Explore tab starts no read by itself: with nothing picked,
//     the repository is not touched.
//
// Existing tests this changes (they are the implementer's to update, not
// edited here): test/health/health_h2_tabs_test.dart ('exactly Last night,
// Today, Trends, Labs'; 'all four fit ... without scrolling' must become five
// dense tabs), test/health/health_h2_migration_test.dart (tabFromLegacy and
// the Labs index), and any golden that pins four tabs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support.dart';

const _five = ['Last night', 'Today', 'Trends', 'Explore', 'Labs'];

Future<void> _bare(WidgetTester t, double width, double scale,
    {required bool dense}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 800);
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: ListView(padding: const EdgeInsets.all(16), children: [
          SubTabs(_five, 0, (_) {}, color: C.blue, dense: dense),
        ]),
      ),
    ),
  ));
  await t.pump();
}

double _maxScroll(WidgetTester t) => t
    .state<ScrollableState>(find
        .descendant(of: find.byType(SubTabs), matching: find.byType(Scrollable))
        .first)
    .position
    .maxScrollExtent;

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

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('the measurement behind the decision (real SubTabs)', () {
    testWidgets('five dense tabs fit 360 pt at 1x without scrolling', (t) async {
      await _bare(t, 360, 1, dense: true);
      expect(_maxScroll(t), 0);
      final labs = t.getRect(find.descendant(
          of: find.byType(SubTabs), matching: find.text('Labs')));
      expect(labs.right, lessThanOrEqualTo(360));
    });

    testWidgets('five default tabs do not: that is why the tab must be dense',
        (t) async {
      await _bare(t, 360, 1, dense: false);
      final labs = find.descendant(
          of: find.byType(SubTabs), matching: find.text('Labs'));
      final fits = labs.evaluate().isNotEmpty &&
          t.getRect(labs).right <= 360 &&
          _maxScroll(t) == 0;
      expect(fits, isFalse);
    });

    testWidgets('at 1.3x text the dense row scrolls rather than overflowing',
        (t) async {
      await _bare(t, 360, 1.3, dense: true);
      expect(t.takeException(), isNull);
      expect(_maxScroll(t), greaterThanOrEqualTo(0));
    });
  });

  group('Health has an Explore sub-tab', () {
    testWidgets('the tabs are Last night, Today, Trends, Explore, Labs', (t) async {
      await _health(t, 0);
      expect(_tabs(t).items, _five);
    });

    testWidgets('the Health tab row is dense and fits 360 and 390 pt at 1x',
        (t) async {
      for (final w in [360.0, 390.0]) {
        await _health(t, 0, width: w);
        expect(_tabs(t).dense, isTrue);
        for (final label in _five) {
          final r = t.getRect(find.descendant(
              of: find.byType(SubTabs), matching: find.text(label)));
          expect(r.left, greaterThanOrEqualTo(0), reason: '$label at $w');
          expect(r.right, lessThanOrEqualTo(w), reason: '$label at $w');
        }
        expect(_maxScroll(t), 0, reason: 'no scrolling at $w pt');
      }
    });

    testWidgets('Explore is the fourth chip and opens the Explorer', (t) async {
      await _health(t, 0);
      expect(find.byType(ExplorerView), findsNothing);
      await t.tap(find.descendant(
          of: find.byType(SubTabs), matching: find.text('Explore')));
      await settle(t);
      expect(_tabs(t).index, 3);
      expect(find.byType(ExplorerView), findsOneWidget);
    });

    testWidgets('tab: 3 opens straight on it; Labs is now tab 4', (t) async {
      await _health(t, 3);
      expect(_tabs(t).index, 3);
      expect(find.byType(ExplorerView), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // a fresh Health, not a rebuilt one
      await _health(t, 4);
      expect(_tabs(t).index, 4);
      expect(find.text('Add a result'), findsOneWidget);
      expect(find.byType(ExplorerView), findsNothing);
    });

    testWidgets('Trends has no Explore toggle: the Explorer is not in two places',
        (t) async {
      await _health(t, 2);
      expect(find.byType(ExplorerView), findsNothing);
      expect(find.byKey(const ValueKey('explore-scale:daily')), findsNothing);
    });

    testWidgets('switching away and back keeps the Explorer usable at 360 pt, 1.3x',
        (t) async {
      await _health(t, 3, scale: 1.3);
      expect(t.takeException(), isNull);
      await t.tap(find.descendant(
          of: find.byType(SubTabs), matching: find.text('Today')));
      await settle(t);
      expect(find.byType(ExplorerView), findsNothing);
      await t.ensureVisible(find.descendant(
          of: find.byType(SubTabs), matching: find.text('Explore')));
      await t.tap(find.descendant(
          of: find.byType(SubTabs), matching: find.text('Explore')));
      await settle(t);
      expect(find.byType(ExplorerView), findsOneWidget);
      expect(t.takeException(), isNull);
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
