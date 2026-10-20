// First-launch consistency: a screen with NO data shows the SAME cards in the
// SAME places as the loaded screen, drawn empty - never different cards.
// Settled empty frame vs settled loaded frame, restricted to the card-level
// ids; content inside a card may differ.
//
// Contract for the green phase: every top-level section of Home and Health
// carries a key 'card:<name>' (the same name in both states).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const p = ShiftPolicy.standard;

  Future<Frame> settled(WidgetTester t, Widget screen, AppState app,
      Future<void> Function(WidgetTester)? drive) async {
    await t.pumpWidget(perfApp(app, screen));
    await settleShell(t);
    if (drive != null) {
      await drive(t);
      await settleShell(t);
    }
    final f = captureFrame(t);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
    return f;
  }

  Future<void> check(WidgetTester t, String name, Widget Function() screen,
      {AppState Function()? emptyApp,
      AppState Function()? loadedApp0,
      Widget Function()? emptyScreen,
      Future<void> Function(WidgetTester)? drive}) async {
    phoneSurface(t);
    final loadedApp = loadedApp0 != null
        ? loadedApp0()
        : (AppState.forTesting()
          ..repo = TabsRepo(homeBundle(
              readiness: 70,
              overnightAt: todayAtMs(8, 42),
              activityAt: todayAtMs(8, 42))));
    final emptyAppState = emptyApp != null
        ? emptyApp()
        : (AppState.forTesting()..repo = EmptyTabsRepo());
    addTearDown(loadedApp.dispose);
    addTearDown(emptyAppState.dispose);
    final empty = await settled(t, (emptyScreen ?? screen)(), emptyAppState, drive);
    final loaded = await settled(t, screen(), loadedApp, drive);

    // Informational on failure: how the two states compare on EVERY id.
    final all = compareLayouts(empty, loaded, p, viewport: shiftViewport);
    printOnFailure(top('$name empty vs loaded, all ids', all, n: 12));
    printOnFailure('$name empty: ${empty.elements.length} elements, '
        'loaded: ${loaded.elements.length}');

    String rects(Frame f) => [
          for (final e in f.elements)
            if (e.id.startsWith('card:'))
              '${e.id} ${e.rect.top.toStringAsFixed(1)}+${e.rect.height.toStringAsFixed(1)}'
        ].join('\n  ');
    printOnFailure('$name empty rects:\n  ${rects(empty)}');
    printOnFailure('$name loaded rects:\n  ${rects(loaded)}');
    final a = cardIds(empty), b = cardIds(loaded);
    expect(b, isNotEmpty, reason: '$name: no top-level section is keyed card:*');
    expect(a, isNotEmpty, reason: '$name: first launch shows no card:* section');
    expect(a, b,
        reason: '$name: first launch and loaded must show the same cards; '
            'only-empty: ${a.difference(b)}, only-loaded: ${b.difference(a)}');
    final r = compareLayouts(empty, loaded, p,
        viewport: shiftViewport, only: cardOrShared);
    printOnFailure(top('$name empty vs loaded, card/shared', r));
    expect(r.findings.where((f) => f.score >= p.warnAt), isEmpty,
        reason: worst(name, r, p));
  }

  testWidgets('Home: empty database vs loaded - same cards, same places',
      (t) => check(t, 'home', () => const HomeScreen(hour: 9)));

  // No repo at all (the database is not open yet): the screen's _d == null
  // path, which draws its own header and its own cards.
  testWidgets('Home: no repo yet vs loaded - same cards, same places',
      (t) => check(t, 'home(no repo)', () => const HomeScreen(hour: 9),
          emptyApp: AppState.forTesting));

  testWidgets('Health: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health', () => const HealthScreen()));

  // Sub-tabs read their own data; each is handed the loaded or the first-launch
  // shape through the constructor's seams - the same objects the loaders build
  // from a populated / an empty database.
  testWidgets('Health Explore: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Explore',
          () => HealthScreen(tab: 1, data: const HealthData(), explore: _exploreLoaded),
          emptyScreen: () => const HealthScreen(
              tab: 1, data: HealthData(), explore: ExploreData())));

  testWidgets('Health Trends: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Trends',
          () => HealthScreen(tab: 2, data: _trendsLoaded()),
          emptyScreen: () => const HealthScreen(tab: 2, data: HealthData())));

  testWidgets('Health Vitals: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Vitals',
          () => HealthScreen(tab: 3, data: _vitalsToday, vitals: _vitalsLoaded()),
          emptyScreen: () => const HealthScreen(
              tab: 3, data: HealthData(), vitals: VitalsData())));

  testWidgets('Health Labs: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Labs',
          () => const HealthScreen(tab: 4, data: HealthData(), labs: _labsLoaded),
          emptyScreen: () => const HealthScreen(
              tab: 4, data: HealthData(), labs: LabsData(markers: kLabMarkers))));

  testWidgets('Sleep: empty database vs loaded - same cards, same places',
      (t) => check(t, 'sleep', () => const SleepTab()));


  // The Activity tab keeps its sub-tab in state; the case opens each by its
  // label, the way a user does.
  for (final (i, label) in [(0, 'For you'), (1, 'Activities'), (2, 'History')]) {
    testWidgets('Activity $label: empty database vs loaded - same cards, same places',
        (t) => check(t, 'activity $label', () => ChangeNotifierProvider(
                create: (_) => UnitsController.seed(UnitSystem.metric),
                child: const WorkoutScreen()),
            loadedApp0: () => AppState.forTesting()..repo = _ActivityRepo(),
            drive: i == 0
                ? null
                : (t) async {
                    final tab = find.widgetWithText(Pressable, label).first;
                    await t.ensureVisible(tab);
                    await t.pump();
                    await t.tap(tab);
                    await t.pump();
                    // ensureVisible may have scrolled the page; both states
                    // are compared from the top.
                    await t.fling(
                        find.byWidgetPredicate((w) =>
                            w is Scrollable && w.axis == Axis.vertical).first,
                        const Offset(0, 2000),
                        4000);
                  }));
  }
}

/// Loaded Activity: a load, a week of heart effort and two sessions.
class _ActivityRepo extends TabsRepo {
  _ActivityRepo()
      : super(homeBundle(
            readiness: 70,
            overnightAt: todayAtMs(8, 42),
            activityAt: todayAtMs(8, 42)));

  @override
  Future<Map<String, dynamic>> getProfile() async => {'weight_kg': 70.0};
  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'load': {
          'value': {'ctl': 42.0, 'atl': 38.0, 'tsb': 4.0},
        },
      };
  @override
  Future<Map<String, dynamic>> getRecords() async => {'workouts_tracked': 2};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    if (metric != 'trimp') return const {'points': []};
    final noon = todayAtMs(12, 0) ~/ 1000;
    return {
      'points': [
        for (var i = 0; i < 7; i++) {'t': noon - i * 86400, 'v': 40.0 + i},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
        'workouts': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'w$i',
              'type': 'Running',
              'start_ts': todayAtMs(7, 0) ~/ 1000 - i * 3600,
              'duration_min': 30,
              'strain': 8.0,
            },
        ],
      };
}

final _exploreLoaded = ExploreData(counts: {
  for (final f in kMetricCatalogue.take(3))
    for (final r in f.rows.take(2)) r.series: 12,
});

HealthData _trendsLoaded() {
  final now = todayAtMs(8, 42) ~/ 1000;
  List<ChartPoint> series(double base) => [
        for (var i = 20; i >= 0; i--)
          (t: now - i * 86400, v: base + (i % 5).toDouble()),
      ];
  return HealthData(charts: {
    'resting_hr': series(55),
    'hrv': series(48),
    'sleep': series(420),
  });
}

const _vitalsToday = HealthData(today: {
  'skin_temp': {'value': 0.3, 'dev_c': 0.3},
});

VitalsData _vitalsLoaded() => VitalsData(
      day: todayId,
      days: [todayId, yesterdayId],
      timeline: {
        'date': todayId,
        'highs': {
          'low_hr': {'v': 52},
          'peak_hr': {'v': 141},
        },
      },
      lungs: const {
        'resp': {'value': 14.5},
      },
      wear: const {'worn_min': 900, 'coverage_pct': 80},
      hrv: const {'rmssd': 55},
    );

const _labsLoaded = LabsData(markers: kLabMarkers, results: [
  {'marker': 'ferritin', 'taken_on': '2026-03-04', 'value': 42, 'unit': 'ng/mL'},
  {'marker': 'hba1c', 'taken_on': '2026-03-04', 'value': 5.2, 'unit': '%'},
]);
