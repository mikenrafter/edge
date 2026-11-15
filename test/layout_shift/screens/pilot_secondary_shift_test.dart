// WHY: pilot loaders that do not all use InlineLoading still need reserved
// geometry. Catches: a blank wearable page, false zero pending count, or a
// short Explorer loader expanding into a full chart after a slow read.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../backup/backup_support.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/live_guide_harness.dart';
import '../../support/shift_run.dart';
import '../../support/pilot_shots.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

class _ReadRepo extends GuideFakeRepo {
  final gate = Completer<void>();
  @override
  Future<int> pendingActivityCount() async { await gate.future; return 2; }
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    await gate.future;
    return MetricRepo().getChart(metric, from: from, to: to, signals: signals);
  }
}

class _BlockedJournalRepo extends GuideFakeRepo {
  int journalReads = 0;
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStress(String day) async => const {};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async => const {'points': []};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String day) {
    journalReads++;
    return Completer<Map<String, JournalMetricValue>>().future;
  }
}

void check(ShiftRun run, String name) {
  final report = run.score(ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0));
  debugPrint(formatShiftReport(name, report, run.probe.frames.length));
  for (final finding in report.findings.where((f) => f.rule == 'shift')) {
    expect(finding.score, lessThan(0.002), reason: '$name: ${finding.elementId}');
  }
  expect(report.total, lessThan(0.016), reason: name);
}

Future<void> landed(ShiftRun run) async {
  for (var i = 0; i < 30; i++) {
    await run.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await run.frames([16]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('pilot_secondary.db');
    await LocalDb.instance;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(kExploreMetricsPref, 'resting_hr');
  });
  tearDownAll(() => env.dispose());

  for (final screen in <String, Widget>{
    'review doorway': const DetectedActivitiesCard(),
    'Explorer': const ExplorerScreen(),
  }.entries) {
    testWidgets('${screen.key} delayed read reserves its content', (t) async {
      phoneSurface(t);
      final repo = _ReadRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final run = ShiftRun(t);
      await t.pumpWidget(pilotShot(perfApp(app, screen.value, brightness: Brightness.dark)));
      run.opened();
      await run.frames([0, 150, 2500]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (screen.key == 'review doorway') {
        final semantics = t.ensureSemantics();
        try {
          await t.pump();
          expect(find.bySemanticsLabel(RegExp('Breakdown of your day')), findsNothing,
            reason: 'an unknown pending count must not announce zero pending items');
        } finally { semantics.dispose(); }
      }
      await takePilotShot(t, screen.key == 'Explorer' ? 'explorer' : 'review-doorway');
      repo.gate.complete();
      await landed(run);
      check(run, screen.key);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('Explorer annotation arrival preserves its plot frame', (t) async {
    phoneSurface(t);
    final repo = _ReadRepo()..gate.complete();
    final annotations = Completer<List<ChartAnnotation>>();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(pilotShot(perfApp(app, SingleChildScrollView(child: ExplorerView(
      annotationLoader: (_, _) => annotations.future)), brightness: Brightness.dark)));
    final setup = ShiftRun(t);
    await landed(setup);
    final run = ShiftRun(t)..opened();
    await run.frames([0, 150, 2500]);
    await takePilotShot(t, 'explorer-annotations');
    annotations.complete([ChartAnnotation(id: 'late-water', kind: AnnotationKind.water,
      at: DateTime.now().millisecondsSinceEpoch / 1000, label: 'Drank water')]);
    await landed(run);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    check(run, 'Explorer late annotations');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });

  // WHY: the Sleep plan has no journal/medication dependency. A stuck journal
  // read must not keep its already available sleep values pending forever.
  testWidgets('Sleep plan settles without reading unrelated journal fields', (t) async {
    phoneSurface(t);
    final repo = _BlockedJournalRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(pilotShot(perfApp(app, const WellnessScreen(sleepPlanOnly: true), brightness: Brightness.dark)));
    await t.pump();
    await takePilotShot(t, 'sleep-plan');
    final run = ShiftRun(t);
    await landed(run);
    expect(repo.journalReads, 0);
    expect(find.byWidgetPredicate((w) => w is PendingContent && w.pending), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('wearable day has a full pending body before cells arrive', (t) async {
    phoneSurface(t);
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(pilotShot(perfApp(app, ValueListenableBuilder<bool>(valueListenable: ready,
      builder: (_, loaded, _) => WearableDayView(device: 'Watch', loaded: loaded,
        hasDay: false)), brightness: Brightness.dark)));
    run.opened();
    await run.frames([0, 150, 2500]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await takePilotShot(t, 'wearable-day');
    ready.value = true;
    await run.frames([0, 16, 100]);
    check(run, 'wearable day');
  });

  testWidgets('legacy moment review waits for SQLite without an empty-state flash', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(pilotShot(perfApp(app, const MomentReviewEditor(), brightness: Brightness.dark)));
    run.opened();
    await run.frames([0, 150, 2500]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await takePilotShot(t, 'legacy-review');
    await landed(run);
    expect(find.text('Nothing to follow up on'), findsOneWidget);
    check(run, 'legacy moment review');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });
}
