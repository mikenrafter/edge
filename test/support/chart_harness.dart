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

Future<void> initPrefs() async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.ensureLoaded();
}

/// A stored `getChart` point: local noon of [day], as the real seam stamps it.
Map<String, dynamic> pt(String day, num v) {
  final p = day.split('-').map(int.parse).toList();
  return {
    't': DateTime(p[0], p[1], p[2], 12).millisecondsSinceEpoch ~/ 1000,
    'v': v,
  };
}

/// Stored chart fixtures for metric, trend and navigation tests.
class ChartRepo extends LocalRepository {
  /// Keyed by the metric string `getChart` is called with (the MetricSpec
  /// `chartKey`, e.g. 'recovery' for readiness).
  final Map<String, List<Map<String, dynamic>>> charts;
  final Map<String, Map<String, dynamic>> timelines;
  final Map<String, Map<String, dynamic>?> calorieCurves;

  /// Stored-history counts per `metric_series` key, for the import-only rows.
  final Map<String, int> counts;

  final List<String> chartCalls = [];
  final List<String> timelineCalls = [];
  final List<String> calorieCalls = [];

  /// When set, every `getChart` waits on it first.
  Completer<void>? gate;

  /// While > 0 every `getChart` throws (and decrements).
  int failChart = 0;

  ChartRepo({
    this.charts = const {},
    this.timelines = const {},
    this.calorieCurves = const {},
    this.counts = const {},
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

/// The value in the series' own cell, for both single- and multi-series
/// panels. The older-calculation `*` is outside this value.
Finder readoutValue(String label) => find.descendant(
    of: find.byKey(ValueKey('chart-key-value:$label')),
    matching: find.byType(Text));

String readoutText(WidgetTester t, String label) {
  final f = readoutValue(label);
  expect(f, findsOneWidget, reason: 'no readout cell for $label');
  final x = t.widget<Text>(f);
  return x.data ?? x.textSpan?.toPlainText() ?? '';
}

/// The panel's caption ("LATEST · 10:00" / "SELECTED · Wed 30 Sep").
String panelCaption(WidgetTester t) {
  final f = find.byKey(ChartKeyReadout.captionKey);
  expect(f, findsOneWidget, reason: 'no panel caption');
  return t.widget<Text>(f).data ?? '';
}
