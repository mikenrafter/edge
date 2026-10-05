// Shared harness for the Data Explorer widget tests (not a test itself).
//
// ASSUMED API used here, besides what explorer_series_test.dart lists:
//
//   lib/ui2/screens/explorer.dart (exported from screens.dart)
//     class ExplorerView extends StatefulWidget {
//       const ExplorerView({super.key, this.today});   // 'YYYY-MM-DD' local; null = todayLabel()
//       static const plotKey = ValueKey('explore-plot');  // the RepaintBoundary around the plot painter
//       static const limitMessage = ...;                  // shown when a 5th metric is refused
//       // keys: explore-scale:daily|day   explore-range:d7|d30|m6|y1|custom
//       //       explore-pick:<key>  explore-chip:<key>  explore-z:<key>
//       //       explore-z-reason:<key>  explore-day-prev|next|label
//       //       explore-empty:<key>  explore-no-data  explore-retry
//       //       explore-normalised-note (Text containing 'Normalised')
//     }
//     class ExplorePlotLine { final String key; final Color color;
//                             final List<List<ExploreXY>> runs; }   // drawn, normalised
//     class ExplorePlotPainter extends CustomPainter {
//       final List<ExplorePlotLine> lines; final List<ExploreBand> bands;
//       final double? selectedAt; }
//   lib/ui2/screens/metric_catalogue.dart (exported from screens.dart)
//     class MetricCatalogueRow { final String key, series, blurb; }
//     class MetricCategory { final String title; final List<MetricCatalogueRow> rows; }
//     const List<MetricCategory> kMetricCatalogue;   // moved out of health_screen.dart
//   prefs (in explorer.dart): kExploreMetricsPref = 'ui.explore_metrics',
//     kExploreIntradayPref = 'ui.explore_intraday', kExploreRangePref =
//     'ui.explore_range', kExploreScalePref = 'ui.explore_scale' ('daily'|'day'),
//     kExploreZPref = 'ui.explore_z'. '' means unset.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fixed "today": every test names its days relative to this one.
const kToday = '2026-10-04';
const kWeek = [
  '2026-09-28',
  '2026-09-29',
  '2026-09-30',
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  '2026-10-04',
];

const kPrefKeys = [
  kExploreMetricsPref,
  kExploreIntradayPref,
  kExploreRangePref,
  kExploreScalePref,
  kExploreZPref,
];

Future<void> initPrefs() async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.ensureLoaded();
}

void clearPrefs() {
  for (final k in kPrefKeys) {
    Prefs.setString(k, '');
  }
}

/// A stored `getChart` point: local noon of [day], as the real seam stamps it.
Map<String, dynamic> pt(String day, num v) {
  final p = day.split('-').map(int.parse).toList();
  return {
    't': DateTime(p[0], p[1], p[2], 12).millisecondsSinceEpoch ~/ 1000,
    'v': v,
  };
}

/// The minimum repository the Explorer reads: `getChart`, `getDayTimeline`,
/// `getDayCalorieCurve`. Everything else throws, which is the point: the
/// Explorer must not need anything else.
class ExplorerRepo extends LocalRepository {
  /// Keyed by the metric string `getChart` is called with (the MetricSpec
  /// `chartKey`, e.g. 'recovery' for readiness).
  final Map<String, List<Map<String, dynamic>>> charts;
  final Map<String, Map<String, dynamic>> timelines;
  final Map<String, Map<String, dynamic>?> calorieCurves;

  final List<String> chartCalls = [];
  final List<String> timelineCalls = [];
  final List<String> calorieCalls = [];

  /// When set, every `getChart` waits on it first.
  Completer<void>? gate;

  /// While > 0 every `getChart` throws (and decrements).
  int failChart = 0;

  ExplorerRepo({
    this.charts = const {},
    this.timelines = const {},
    this.calorieCurves = const {},
  });

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    chartCalls.add(metric);
    final g = gate;
    if (g != null) await g.future;
    if (failChart > 0) {
      failChart--;
      throw StateError('read failed');
    }
    return {'points': charts[metric] ?? const []};
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async {
    timelineCalls.add(date);
    return timelines[date] ?? const {};
  }

  @override
  Future<Map<String, dynamic>?> getDayCalorieCurve(String day) async {
    calorieCalls.add(day);
    return calorieCurves[day];
  }
}

Future<void> loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

Widget providers(AppState app, Widget home, {double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
            create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        Provider<Capabilities>.value(
            value: Capabilities(CapabilityInputs())),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: home),
      ),
    );

/// Pumps [ExplorerView] inside a list (as a screen does), over [repo].
Future<void> pumpExplorer(
  WidgetTester t,
  ExplorerRepo repo, {
  double width = 390,
  double height = 3000,
  double scale = 1,
  String today = kToday,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, height);
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(providers(
    app,
    ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [ExplorerView(today: today)],
    ),
    scale: scale,
  ));
  await settle(t);
}

/// Bounded pumps until [done] is true (default: a few frames). Never
/// pumpAndSettle: an InlineLoading spinner never settles.
Future<void> settle(WidgetTester t, {bool Function()? done}) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(milliseconds: 50));
    if (done != null && done()) return;
    if (done == null && i >= 5) return;
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  expect(f, findsOneWidget, reason: '$key is not on screen exactly once');
  await t.ensureVisible(f);
  await t.tap(f);
  await settle(t);
}

Finder pick(String key) => find.byKey(ValueKey('explore-pick:$key'));
Finder chip(String key) => find.byKey(ValueKey('explore-chip:$key'));

/// The painter the plot actually draws with.
ExplorePlotPainter plotPainter(WidgetTester t) {
  final boundary = find.byKey(ExplorerView.plotKey);
  expect(boundary, findsOneWidget, reason: 'no plot is on screen');
  final all = t.widgetList<CustomPaint>(
      find.descendant(of: boundary, matching: find.byType(CustomPaint)));
  return all.map((c) => c.painter).whereType<ExplorePlotPainter>().single;
}

ExplorePlotLine plotLine(WidgetTester t, String key) =>
    plotPainter(t).lines.singleWhere((l) => l.key == key);

List<int> runLens(ExplorePlotLine l) => [for (final r in l.runs) r.length];

/// Taps the plot at [frac] (0..1) across its width.
Future<void> scrubAt(WidgetTester t, double frac) async {
  final r = t.getRect(find.byKey(ExplorerView.plotKey));
  await t.tapAt(Offset(r.left + r.width * frac, r.center.dy));
  await t.pump();
}

Finder readoutValue(String label) =>
    find.byKey(ValueKey('chart-key-value:$label'));

String readoutText(WidgetTester t, String label) {
  final f = readoutValue(label);
  expect(f, findsOneWidget, reason: 'no readout cell for $label');
  final texts = t.widgetList<Text>(
      find.descendant(of: f, matching: find.byType(Text)));
  return [for (final x in texts) x.data ?? x.textSpan?.toPlainText() ?? ''].join();
}
