// APK1 composes the existing shell/DB/settings fixtures. No future lib API is
// referenced: missing controls fail finder expectations, never compilation.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../backup/backup_support.dart';
import 'as_of_recalc_fakes.dart' show settle;
import 'bundled_fonts.dart';
import 'tabs_consistency_fakes.dart';
import 'themed_settings_helpers.dart' show g123View;

/// Fixed LOCAL calendar, including noon stamps, independent of host timezone.
final apk1Now = DateTime(2026, 10, 4, 15, 40);
const apk1Day = '2026-10-04';

/// A real metric fixture, not a computed fallback.
Metric apk1Metric(double value) =>
    Metric(value: value, confidence: .9, tier: MetricTier.high);

/// Three competing reasons: equal-severity recovery and sleep, then strain.
HomeData apk1Home({String? observation = 'red', String? observedDay = apk1Day,
    bool bare = false, bool reviewFailed = false, int pending = 2}) => HomeData(
  dayId: apk1Day,
  readiness: bare ? Metric.empty : apk1Metric(20),
  sleepMin: bare ? Metric.empty : apk1Metric(300),
  sleepNeedMin: bare ? Metric.empty : apk1Metric(480),
  strain: bare ? Metric.empty : apk1Metric(15),
  strainTarget: bare ? null : const {'low': 8, 'high': 12},
  illnessState: observation,
  illnessDay: observedDay,
  illnessZ: 2.5,
  pendingActivities: reviewFailed ? null : pending,
  pendingActivitiesFailed: reviewFailed,
);

/// Reuses the all-tab repository, replacing its run-date sleep fixtures with
/// a fixed local night. Only boundary reads are faked; widgets are production.
class Apk1Repo extends TabsRepo {
  Apk1Repo() : super(const {});
  final openedNights = <String>[];
  @override
  Future<List<String>> availableDays() async => [apk1Day, '2026-10-03'];
  @override
  Future<Map<String, dynamic>> getToday() async => const {
    'status': {'today_day': apk1Day},
  };
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    openedNights.add(date);
    return apk1Sleep().night;
  }
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day, {
    required List<String> chartKeys, required int windowDays, String? before,
  }) async => SleepDetailBundle(
    night: await getDaySleepV2(day), timeline: const {},
    insights: await getInsights(), charts: const {}, windows: const [],
  );
  @override
  Future<Map<String, dynamic>> getInsights() async => const {
    'sleep_coach': {
      'need': {'value': {'need_sec': 28800}},
      'bedtime': {'value': {'bedtime_min_of_day': 1320}},
    },
    'sleep_debt': {'value': {'debt_hours': 2.0}},
  };
  @override
  Future<List<ActivitySuggestion>> pendingActivities() async => const [];
}

SleepData apk1Sleep() {
  final onset = DateTime(2026, 10, 3, 23).millisecondsSinceEpoch ~/ 1000;
  final wake = DateTime(2026, 10, 4, 7).millisecondsSinceEpoch ~/ 1000;
  return SleepData(day: apk1Day, night: {
    'duration_min': 450, 'in_bed_min': 480, 'awake_min': 30,
    'efficiency': .9375, 'onset_ts': onset, 'wake_ts': wake,
    'light_min': 240, 'deep_min': 120, 'rem_min': 90,
    'hypnogram': [
      {'t': onset, 'stage': 'light'},
      {'t': onset + 2 * 3600, 'stage': 'deep'},
      {'t': onset + 4 * 3600, 'stage': 'rem'},
      {'t': onset + 330 * 60, 'stage': 'light'},
      {'t': onset + 450 * 60, 'stage': 'awake'},
      {'t': wake, 'stage': 'awake'},
    ],
  });
}

/// Route ledger observes the real Navigator, including duplicates immediately
/// popped again. Checking depth alone would miss push-then-pop implementations.
class Apk1Routes extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    pushes++;
  }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);
}

Future<BackupEnv> apk1Environment(String name) async {
  final env = await BackupEnv.create(name);
  await Prefs.ensureLoaded();
  await loadFonts();
  return env;
}

/// Clear the existing instance so Prefs' synchronous cache stays the same
/// instance as the settings writer. Do not replace the mock store per test.
Future<void> apk1ClearPrefs() async {
  final sp = await SharedPreferences.getInstance();
  await sp.clear();
  await sp.reload();
}

Future<void> apk1Settle(WidgetTester t) => settle(t, n: 16);

/// Keep clock-based day labels fixed across every awaited frame and gesture.
/// The semantics handle is disposed inside the test body: addTearDown runs
/// after the binding's active-handle check and would fail every test.
void apk1Test(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (t) async {
      try {
        await withClock(Clock.fixed(apk1Now), () => body(t));
      } finally {
        _apk1Semantics?.dispose();
        _apk1Semantics = null;
      }
    });

SemanticsHandle? _apk1Semantics;

/// Same providers and real tab builder as shellApp/perfApp; adds settings
/// controllers and a route observer. [source] mounts a real link-owning screen
/// as Today's content so each link can be isolated without a setup push.
Future<AppState> apk1Mount(WidgetTester t, {
  Widget? source, Widget? page, Apk1Routes? routes,
  double scale = 1, double height = 800,
  ShellDomain initial = ShellDomain.today,
  Apk1Repo? repo,
}) async {
  g123View(t, width: 360, height: height);
  _apk1Semantics ??= t.ensureSemantics();
  final app = AppState.forTesting()..repo = repo ?? Apk1Repo();
  addTearDown(app.dispose);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => LocaleController.seed('en')),
      ChangeNotifierProvider(create: (_) =>
          ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(create: (_) => ClockFormatController.seed(ClockFormat.h24)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.android),
      navigatorObservers: [if (routes != null) routes],
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: page ?? AppShell(initial: initial, builder: (c, d) => switch (d) {
        ShellDomain.today => source ?? HomeScreen(data: apk1Home(), now: apk1Now),
        ShellDomain.sleep => const SleepTab(),
        ShellDomain.activity => const WorkoutScreen(),
        ShellDomain.health => const HealthScreen(data: HealthData()),
      }),
    ),
  ));
  await apk1Settle(t);
  return app;
}

final apk1TabBar = find.byKey(const ValueKey<String>('shared:tabbar'));
final apk1Rings = find.byKey(const ValueKey<String>('card:rings'));

/// Reads the selected tab from the real shell, without a new controller API.
int apk1Selected(WidgetTester t) {
  final shell = find.byType(AppShell, skipOffstage: false);
  expect(shell, findsOneWidget, reason: 'the shell remains mounted under details');
  return t.widget<IndexedStack>(find.descendant(
    of: shell, matching: find.byType(IndexedStack, skipOffstage: false),
    skipOffstage: false,
  ).first).index!;
}

Future<void> apk1Reveal(WidgetTester t, Finder target) async {
  // A missing proposed key must fail an EXPECTATION, not scrollUntilVisible's
  // StateError. Walk the real lazy list, then assert the target exists.
  for (var i = 0; i < 100 && target.evaluate().isEmpty; i++) {
    expect(apk1VerticalScroll, findsWidgets);
    final p = t.state<ScrollableState>(apk1VerticalScroll.first).position;
    if (p.pixels >= p.maxScrollExtent) {
      // A lazy footer (the real sleep plan) can still be loading from SQLite.
      // Give that existing fixture's async reads time to land before deciding
      // the requested control is absent.
      await apk1Settle(t);
      if (target.evaluate().isNotEmpty || p.pixels >= p.maxScrollExtent) break;
    }
    p.jumpTo((p.pixels + 180).clamp(p.minScrollExtent, p.maxScrollExtent));
    await t.pump();
  }
  expect(target, findsOneWidget, reason: 'the requested control must be reachable in the page');
  await t.ensureVisible(target);
  await t.pump();
}

final apk1VerticalScroll = find.byWidgetPredicate((w) => w is Scrollable &&
    (w.axisDirection == AxisDirection.down || w.axisDirection == AxisDirection.up));

/// The complete spoken tree, including merged nodes, for duplicate status
/// checks. Unlike counting Text widgets, this catches repeated announcements.
List<String> apk1Spoken(WidgetTester t) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final label = node.label;
    if (label.isNotEmpty) labels.add(label);
    if (node.value.isNotEmpty) labels.add(node.value);
    node.visitChildren((child) { visit(child); return true; });
  }
  visit(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return labels;
}
