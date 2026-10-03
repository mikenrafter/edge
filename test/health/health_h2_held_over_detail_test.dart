// 8AF review finding: held-over night rows opened details for a different time
// scope. After days without a sync, Health → Last night labels the older night
// and shows its readiness, HRV, resting heart rate, respiratory rate and stress.
// Tapping Readiness opened a detail that refused a held-over night, and tapping
// the others opened MetricDetail on Today, which said "Nothing recorded today"
// beside a number the tapped row had just shown. Only Sleep got the night.
//
// Each row is tapped and what the detail then shows is read: the tapped night's
// own value and date, not today's.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Three days ago, so the night is neither today nor yesterday.
final _night = dayLabelOf(DateTime.now().subtract(const Duration(days: 3)));

Map<String, dynamic> _env(num v, {String tier = 'ESTIMATE', String? unit}) => {
      'value': v,
      'confidence': .7,
      'tier': tier,
      'unit': ?unit,
    };

int _noon(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo, 12)
          .millisecondsSinceEpoch ~/
      1000;
}

/// Held over: today has not settled, so the overnight block is the night three
/// days ago.
Map<String, dynamic> _today() => {
      'status': {
        'today_day': todayLabel(),
        'overnight_day': _night,
        'showing_prior_overnight': true,
        'overnight_state': 'ready',
      },
      'daily': {
        'readiness': _env(82, tier: 'HIGH'),
        'resting_hr': _env(52, tier: 'HIGH', unit: 'bpm'),
      },
      'sleep': {'duration_min': _env(465)},
      'hrv': {'rmssd': 68, 'confidence': .6},
      'stress': {
        'value': 28,
        'score': 28,
        'level': 'Low',
        'confidence': .55,
        'tier': 'ESTIMATE',
      },
      'resp': {'value': 14.2, 'confidence': .6},
    };

/// The value the night has in each stored series, distinct per series so a
/// detail showing the wrong series cannot pass.
const _stored = {
  'recovery': 82.0,
  'hrv': 68.0,
  'resting_hr': 52.0,
  'rhr': 52.0,
  'resp_rate': 14.0,
  'stress': 28.0,
};

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => _today();

  /// One stored point: the held-over night. Today has none.
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {
        'points': [
          {'t': _noon(3), 'v': _stored[metric] ?? 50.0},
        ],
      };

  @override
  Future<List<String>> availableDays() async {
    final n = DateTime.now();
    return [for (var i = 0; i < 40; i++) dayLabelOf(DateTime(n.year, n.month, n.day - i))];
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async =>
      const {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
}

HealthData _data() => HealthData(
      today: _today(),
      charts: const {},
      daysWithData: 24,
      napDay: _night,
    );

Future<void> _pump(WidgetTester t) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(390, 8000);
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = _Repo();
  addTearDown(app.dispose);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      Provider<Capabilities>.value(
          value: Capabilities(const CapabilityInputs())),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: HealthScreen(
            data: _data(), vitals: const VitalsData(), tab: 0),
      ),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder _inDetail(Type detail, Finder f) =>
    find.descendant(of: find.byType(detail), matching: f);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_held_over_detail_test.db';
  });

  final nightPretty = prettyDay(_night);

  testWidgets('Readiness opens on the held-over night and shows its score',
      (t) async {
    await _pump(t);
    await t.tap(find.text('Readiness'));
    await _settle(t);
    expect(find.byType(ReadinessDetail), findsOneWidget);
    expect(_inDetail(ReadinessDetail, find.text('82')), findsOneWidget,
        reason: 'the night\'s own readiness, not an absence');
    expect(_inDetail(ReadinessDetail, find.text('Readiness is not scored')),
        findsNothing);
    expect(_inDetail(ReadinessDetail, find.textContaining(nightPretty)),
        findsWidgets,
        reason: 'and it says which night it is');
  });

  for (final (label, key, value) in <(String, String, String)>[
    ('HRV', 'hrv', '68'),
    ('Resting heart rate', 'resting_hr', '52'),
    ('Respiratory rate', 'resp_rate', '14'),
    ('Overnight stress', 'stress', '28'),
  ]) {
    testWidgets('$label opens $key on the held-over night, not on Today',
        (t) async {
      await _pump(t);
      await t.tap(find.text(label));
      await _settle(t);
      expect(
          t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
      expect(_inDetail(MetricDetail, find.text('Nothing recorded today')),
          findsNothing,
          reason: 'the row showed a value; the detail cannot say there is none');
      expect(_inDetail(MetricDetail, find.text(nightPretty)), findsWidgets,
          reason: 'the selected day is the tapped night');
      expect(_inDetail(MetricDetail, find.textContaining(value)), findsWidgets,
          reason: 'with its value');
    });
  }
}
