// Scrub panel on every chart (owner decision 2026-10-22, ui-feedback item 1):
// an always-present inset under the chart, fixed height, default = latest
// point. RED tests. The contract (keys, text) is documented in
// support/scrub_panel_laws.dart; gestures are NOT touched here (item 2).
//
// Charts: metric detail RHR (line, Scrubber), workout 7-day bars, the month
// grid row. The Explorer is in ui2_scrub_panel_explorer_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/month_grid.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart'
    show MetricData, MetricDetail, specOf, WorkoutScreen;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';
import 'support/older_version_fixtures.dart';
import 'support/scrub_panel_laws.dart';

Widget _scaled(double scale, Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

final _rhr = PanelRig(
  'metric detail, resting heart rate (line)',
  open: (t, {width = 390, scale = 1, olderLatest = false}) async {
    _phone(t, width, 1800);
    final d = await MetricData.load(
        OlderRepo(charts: {
          specOf('resting_hr').chartKey:
              panelSeries(10, olderLatest: olderLatest)
        }),
        'resting_hr',
        journal: false);
    await t.pumpWidget(
        _scaled(scale, Scaffold(body: MetricDetail('resting_hr', data: d))));
    await t.pumpAndSettle();
    await t.tap(find.text('7 days'));
    await t.pumpAndSettle();
  },
  scrubBack: (t, back) async {
    final r = t.getRect(find
        .descendant(
            of: find.byType(ChartFrame).first, matching: find.byType(Scrubber))
        .first);
    // 7 slots, the last is today; slot i sits at i / 6 across the strip.
    await t.tapAt(Offset(r.left + r.width * (6 - back) / 6, r.center.dy));
    await t.pumpAndSettle();
  },
  scope: find.byType(ChartFrame),
  seriesColor: (t) =>
      P.of(t.element(find.byType(ChartFrame).first)).on(specOf('resting_hr').color),
  valueAt: (back) => '${50 + back}bpm',
  minStats: 2,
);

Future<void> _openWorkout(WidgetTester t,
    {double width = 390, double scale = 1, bool olderLatest = false}) async {
  _phone(t, width, 2400);
  final app = AppState.forTesting()
    ..repo = OlderRepo(
        charts: {'trimp': panelSeries(7, olderLatest: olderLatest)});
  addTearDown(app.dispose);
  await t.pumpWidget(_scaled(
      scale,
      ChangeNotifierProvider<AppState>.value(
          value: app, child: const Scaffold(body: WorkoutScreen()))));
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(milliseconds: 25));
  }
}

Finder _effortFrame() => find.byWidgetPredicate(
    (w) => w is ChartFrame && w.title == 'Heart effort by day');

final _bars = PanelRig(
  'workout, heart effort by day (7 bars)',
  open: (t, {width = 390, scale = 1, olderLatest = false}) =>
      _openWorkout(t, width: width, scale: scale, olderLatest: olderLatest),
  scrubBack: (t, back) async {
    final strip = find.byWidgetPredicate(
        (w) => w is ChartScrub && w.label == 'Heart effort by day');
    await t.ensureVisible(strip);
    final r = t.getRect(strip);
    await t.tapAt(Offset(r.left + r.width * (6 - back + .5) / 7, r.center.dy));
    await t.pump();
  },
  scope: _effortFrame(),
  seriesColor: (t) => t
      .widget<ChartScrub>(find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == 'Heart effort by day'))
      .keys
      .first
      .color,
  valueAt: (back) => '${50 + back}points',
);

Finder _gridScrub() => find.byWidgetPredicate(
    (w) => w is ChartScrub && w.label == specOf('strain').title);

final _grid = PanelRig(
  'month grid row (plain scrub readout)',
  open: (t, {width = 390, scale = 1, olderLatest = false}) async {
    _phone(t, width, 1600);
    final rows = await loadGridRows(OlderRepo(charts: {
      specOf('strain').chartKey: panelSeries(30, olderLatest: olderLatest)
    }));
    await t.pumpWidget(_scaled(
        scale,
        Scaffold(body: SingleChildScrollView(child: MonthGrid(rows)))));
    await t.pumpAndSettle();
  },
  scrubBack: (t, back) async {
    // The plot only: the ChartScrub rect also holds the taller panel below.
    final r = t.getRect(
        find.descendant(of: _gridScrub(), matching: find.byType(Scrubber)));
    await t.tapAt(Offset(r.left + r.width * (29 - back + .5) / 30, r.center.dy));
    await t.pump();
  },
  // The row: its title, strip and readout, up to the next row's divider.
  scope: find.byType(MonthGrid),
  seriesColor: (t) => t.widget<ChartScrub>(_gridScrub()).keys.first.color,
);

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  panelLaws(_rhr);
  panelLaws(_bars);
  panelLaws(_grid);

  group('metric detail RHR: the stats and the old pop-in', () {
    testWidgets('at rest the panel carries 7-day avg and vs avg (mock)',
        (t) async {
      await _rhr.open(t);
      final panel = panelOf(_rhr);
      expect(panel, findsOneWidget);
      final texts = [
        for (final x in t.widgetList<Text>(
            find.descendant(of: statsIn(panel), matching: find.byType(Text))))
          (x.data ?? '').replaceAll(RegExp(r'\s+'), ' ')
      ];
      // Window 7 days, a gap at 2: 50,51,53,54,55,56 -> mean 53.17.
      expect(texts, contains('53 bpm'));
      expect(texts.where((s) => RegExp(r'^[+\-−]3 bpm$').hasMatch(s)),
          isNotEmpty,
          reason: 'vs avg for the latest day (50 vs 53.17)');
    });

    testWidgets('a current latest reading keeps the older headline reason',
        (t) async {
      final handle = t.ensureSemantics();
      await _rhr.open(t);
      expect(olderNote('headline'), findsOneWidget);
      expect(noteIn(panelOf(_rhr)), findsNothing);
      expect(spokenOlder(t, 104), 1);
      handle.dispose();
    });

    testWidgets('distinct headline and latest reasons are both kept',
        (t) async {
      final handle = t.ensureSemantics();
      _phone(t, 390, 1800);
      final points = panelSeries(10, olderLatest: true);
      for (final point in points) {
        if (point['from_older_version'] != null) {
          point['older_version_reason'] = 'need_input:name=height_cm';
          if (point['v'] == 54) {
            point['from_older_version'] = 103;
            point['older_version_reason'] = 'need_input:name=age';
          }
        }
      }
      final d = await MetricData.load(
          OlderRepo(charts: {specOf('resting_hr').chartKey: points}),
          'resting_hr', journal: false);
      await t.pumpWidget(_scaled(1,
          Scaffold(body: MetricDetail('resting_hr', data: d))));
      await t.pumpAndSettle();
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
      expect(olderNote('headline'), findsOneWidget);
      expect(noteIn(panelOf(_rhr)), findsOneWidget);
      expect(t.widget<Text>(olderNote('headline')).data,
          contains('From an older calculation (v103)'));
      expect(t.widget<Text>(olderNote('readout')).data,
          contains('From an older calculation (v104)'));
      expect(t.widget<Text>(olderNote('headline')).data, contains('age'));
      expect(t.widget<Text>(olderNote('readout')).data, contains('height'));
      expect(spokenOlder(t, 103), 1);
      expect(spokenOlder(t, 104), 1);
      handle.dispose();
    });

    testWidgets('a difference that rounds to zero has no sign', (t) async {
      _phone(t, 390, 1800);
      // 60 selected against a 7-day average of 60.14.
      final points = [
        for (var back = 9; back >= 0; back--) cp(back, back == 0 ? 61 : 60)
      ];
      final d = await MetricData.load(
          OlderRepo(charts: {specOf('resting_hr').chartKey: points}),
          'resting_hr',
          journal: false);
      await t.pumpWidget(
          _scaled(1, Scaffold(body: MetricDetail('resting_hr', data: d))));
      await t.pumpAndSettle();
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
      await _rhr.scrubBack(t, 3);
      final texts = [
        for (final x in t.widgetList<Text>(find.descendant(
            of: statsIn(panelOf(_rhr)), matching: find.byType(Text))))
          (x.data ?? '').replaceAll(RegExp(r'\s+'), ' ')
      ];
      expect(texts, contains('0 bpm'));
      expect(texts.where((s) => s.contains('−0') || s.contains('+0')), isEmpty);
    });

    testWidgets('the 7-day avg and vs avg are spoken', (t) async {
      final handle = t.ensureSemantics();
      await _rhr.open(t);
      expect(find.bySemanticsLabel(RegExp(r'^7-day avg 53 bpm$')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^vs avg ')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the picked day no longer pops in as a separate card: the '
        'scroll extent does not change on a scrub', (t) async {
      await _rhr.open(t);
      double extent() => t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .maxScrollExtent;
      final before = extent();
      await _rhr.scrubBack(t, PanelRig.scrubbedBack);
      expect(extent(), before);
      // The panel has to be there for "nothing pops in" to mean anything.
      expect(panelOf(_rhr), findsOneWidget);
    });
  });
}
