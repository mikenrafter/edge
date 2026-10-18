// One value once per scope, one name per metric, one illness card,
// one HRV detail (AGENTS.md 4.10).
//
// Every assertion here reads the rendered widgets, not the source, so it holds
// whichever way the screens get their names (the shared table in
// metric_labels.dart is pinned in health_h2_label_table_test.dart). Counting is
// done on `MetricRow.name` / `TrendCard.label`, not on find.text, because a
// metric's name can legitimately also appear in a sub-label or a status card.
//
// Health is pumped the way the existing goldens and ui2_wiring_r2_test do it:
// `HealthScreen(data:, vitals:, tab:)` with no AppState, so nothing here waits
// on a database. The sub-tab order is Last night 0, Today 1, Trends 2, Labs 3.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _env(num v, {String tier = 'ESTIMATE'}) => {
      'value': v,
      'confidence': .8,
      'tier': tier,
      'inputs_used': const <String>[],
    };

int _noon(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo, 12)
          .millisecondsSinceEpoch ~/
      1000;
}

List<ChartPoint> _series(int n, double base) => [
      for (var i = n - 1; i >= 0; i--) (t: _noon(i), v: base + (i % 5)),
    ];

/// A night with every overnight row present and a nap, so "once" means once and
/// a missing row is a failure rather than a pass.
HealthData _fullNight({Map<String, dynamic>? illness}) => HealthData(
      today: {
        'daily': {
          'resting_hr': _env(52, tier: 'HIGH'),
          'readiness': _env(82, tier: 'HIGH'),
          'strain': _env(12.4),
          'steps': _env(8100),
          'active_min': _env(46),
          'calories': _env(640),
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
        'skin_temp': {
          'value': 0.31,
          'confidence': .5,
          'tier': 'RELATIVE',
          'inputs_used': const ['skin_temp_raw'],
        },
        'illness': illness ?? {'state': 'green'},
      },
      charts: {
        'resting_hr': _series(30, 50),
        'hrv': _series(30, 60),
        'sleep': _series(30, 420),
        'stress': _series(30, 30),
        'resp_rate': _series(30, 14),
      },
      daysWithData: 20,
      napCount: 1,
      napMin: 30,
      napDay: todayLabel(),
    );

VitalsData _vitals() => VitalsData(
      day: todayLabel(),
      days: [todayLabel()],
      timeline: const {
        'highs': {
          'low_hr': {'v': 48},
          'peak_hr': {'v': 151},
        },
      },
      lungs: const {
        'resp': {'value': 14.2},
      },
      wear: const {'worn_min': 900, 'coverage_pct': 62},
      hrv: const {'rmssd': 68},
    );

/// Bounded pumps, not pumpAndSettle: a sub-tab that is still loading shows a
/// spinner that never settles, and "timed out" would hide what is on screen.
Future<void> _settled(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpHealth(WidgetTester t, HealthData d,
    {int tab = 0, VitalsData? vitals}) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  // A pushed detail route reads the theme controller, so the providers a real
  // app has are here too.
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: HealthScreen(
              key: UniqueKey(), data: d, vitals: vitals, tab: tab)),
    ),
  ));
  await _settled(t);
}

/// How many rows or cards on screen carry [name] as their name.
int _named(WidgetTester t, String name) =>
    t.widgetList<MetricRow>(find.byType(MetricRow)).where((r) => r.name == name).length +
    t.widgetList<TrendCard>(find.byType(TrendCard)).where((c) => c.label == name).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Trends will read the metric catalogue from sqflite; keep it on an empty
  // test database so a missing read cannot be mistaken for a missing feature.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_labels_test.db';
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Home uses the shared names', () {
    final home = HomeData(
      name: 'Alex',
      dayId: todayLabel(),
      readiness: const Metric(value: 82, confidence: .8, tier: MetricTier.high),
      sleepMin: const Metric(
          value: 465, unit: 'min', confidence: .8, tier: MetricTier.estimate),
      strain: const Metric(value: 14.2, confidence: .6, tier: MetricTier.estimate),
      rhr: const Metric(
          value: 52, unit: 'bpm', confidence: .8, tier: MetricTier.high),
      steps: const Metric(
          value: 8642, unit: 'steps', confidence: .6, tier: MetricTier.estimate),
    );

    testWidgets('Home says "Resting heart rate", not "Heart rate" over "Resting"',
        (t) async {
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: HomeScreen(data: home, hour: 9))));
      await t.pump();
      expect(find.text('Resting heart rate'), findsOneWidget);
      expect(find.text('Heart rate'), findsNothing,
          reason: 'the old two-part name must be gone, not kept beside it');
      expect(find.text('Resting'), findsNothing,
          reason: '"Resting" was a sub-label that only existed to finish the name');
    });

    testWidgets('Home keeps the shared names for steps and strain', (t) async {
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: HomeScreen(data: home, hour: 9))));
      await t.pump();
      expect(find.text('Steps'), findsWidgets);
      // The ring prints its label in capitals.
      expect(find.text('STRAIN'), findsWidgets);
    });
  });

  group('Health · Last night names each metric once', () {
    testWidgets('every overnight metric appears exactly once, by its shared name',
        (t) async {
      await _pumpHealth(t, _fullNight());
      for (final name in const [
        'Readiness',
        'Sleep',
        'HRV',
        'Resting heart rate',
        'Respiratory rate',
        'Overnight stress',
        'Skin temperature',
        'Daytime sleep',
      ]) {
        expect(_named(t, name), 1, reason: '"$name" on Last night');
      }
    });

    testWidgets('Last night does not call stress anything but "Overnight stress"',
        (t) async {
      await _pumpHealth(t, _fullNight());
      expect(_named(t, 'Stress'), 0);
    });

    testWidgets('Last night does not call sleep "Time asleep"', (t) async {
      await _pumpHealth(t, _fullNight());
      expect(_named(t, 'Time asleep'), 0);
    });
  });

  group('Health · Today names each metric at most once', () {
    testWidgets('strain, steps, calories, wear: none repeated', (t) async {
      await _pumpHealth(t, _fullNight(), tab: 1, vitals: _vitals());
      for (final name in const [
        'Strain',
        'Steps',
        'Active minutes',
        'Calories',
        'Wear time',
      ]) {
        expect(_named(t, name), lessThanOrEqualTo(1), reason: '"$name" on Today');
      }
    });

    testWidgets('overnight metrics are not repeated on Today', (t) async {
      await _pumpHealth(t, _fullNight(), tab: 1, vitals: _vitals());
      for (final name in const [
        'HRV',
        'Resting heart rate',
        'Respiratory rate',
        'Overnight stress',
        'Skin temperature',
        'Sleep',
      ]) {
        expect(_named(t, name), 0,
            reason: '"$name" belongs to Last night, one scope per tab');
      }
    });
  });

  group('Health · Trends names each metric at most once', () {
    testWidgets('no metric is listed twice and sleep is never "Time asleep"',
        (t) async {
      await _pumpHealth(t, _fullNight(), tab: 2);
      for (final name in const [
        'Resting heart rate',
        'HRV',
        'Sleep',
        'Respiratory rate',
        'Skin temperature',
        'Strain',
        'Steps',
        'Stress',
        'Readiness',
      ]) {
        expect(_named(t, name), lessThanOrEqualTo(1), reason: '"$name" on Trends');
      }
      expect(_named(t, 'Time asleep'), 0,
          reason: '"Time asleep" is only ever a sub-label');
    });
  });

  group('one HRV detail path', () {
    testWidgets('the Last night HRV row opens MetricDetail("hrv")', (t) async {
      await _pumpHealth(t, _fullNight());
      await t.tap(find.byWidgetPredicate((w) => w is MetricRow && w.name == 'HRV'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
          find.byWidgetPredicate(
              (w) => w is MetricDetail && w.metricKey == 'hrv'),
          findsOneWidget);
      expect(find.byType(Investigate), findsNothing,
          reason: 'Investigate is one tap further, from MetricDetail');
    });

    testWidgets('the Vitals "Heart rate variability" deep dive is gone from every tab',
        (t) async {
      for (final tab in [0, 1, 2, 3]) {
        await _pumpHealth(t, _fullNight(), tab: tab, vitals: _vitals());
        expect(find.byType(DeepDiveCard), findsNothing, reason: 'tab $tab');
        expect(find.text('Deep dives'), findsNothing, reason: 'tab $tab');
        expect(find.text('Heart rate variability'), findsNothing,
            reason: 'tab $tab');
      }
    });
  });

  group('one illness card, shared by Home and Health', () {
    Future<Observation> homeCard(WidgetTester t, String state, double? z) async {
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
              body: HomeScreen(
                  data: HomeData(dayId: todayLabel()).copyOrIllness(
                      state, todayLabel(), z),
                  hour: 9))));
      await t.pump();
      return t.widget<Observation>(find.byType(Observation));
    }

    Future<Observation> healthCard(
        WidgetTester t, String state, double? z) async {
      await _pumpHealth(
          t,
          _fullNight(illness: {
            'state': state,
            'date': todayLabel(),
            'z': ?z,
          }));
      return t.widget<Observation>(find.byType(Observation));
    }

    for (final (state, z) in <(String, double?)>[
      ('amber', 1.8),
      ('amber', -1.3),
      ('amber', null),
      ('red', 3.1),
    ]) {
      testWidgets('$state, z=$z: the words are the same on both screens',
          (t) async {
        final onHome = await homeCard(t, state, z);
        final onHealth = await healthCard(t, state, z);
        expect(onHealth.headline, onHome.headline);
        expect(onHealth.detail, onHome.detail);
        expect(onHealth.advice, onHome.advice);
      });
    }
  });
}
