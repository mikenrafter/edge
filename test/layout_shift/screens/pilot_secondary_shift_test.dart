import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
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
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
// The baseline screenshot run uses the old barrel, before this export.
// ignore: unnecessary_import
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
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
  Future<int> pendingActivityCount() async {
    await gate.future;
    return 2;
  }

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    await gate.future;
    return MetricRepo().getChart(metric, from: from, to: to, signals: signals);
  }
}

class _LatePlanRepo extends GuideFakeRepo {
  int insightsReads = 0;
  final gate = Completer<void>();
  @override
  Future<Map<String, dynamic>> getInsights() async {
    insightsReads++;
    await gate.future;
    return {
      'sleep_coach': {
        'need': {
          'value': {'need_sec': 28800},
        },
        'bedtime': {
          'value': {'bedtime_min_of_day': 1320},
        },
        'wake': {
          'value': {'wake_min_of_day': 420},
        },
        'nap_credit_min': {'value': 20},
        'strain_bonus_min': {'value': 30},
      },
      'sleep_debt': {
        'value': {'debt_hours': 1},
      },
    };
  }
}

class _BlockedJournalRepo extends GuideFakeRepo {
  int journalReads = 0;
  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStress(String day) async => const {};
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => const {'points': []};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String day) {
    journalReads++;
    return Completer<Map<String, JournalMetricValue>>().future;
  }
}

void check(ShiftRun run, String name) {
  final report = run.score(
    ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0),
  );
  debugPrint(formatShiftReport(name, report, run.probe.frames.length));
  for (final finding in report.findings.where((f) => f.rule == 'shift')) {
    expect(
      finding.score,
      lessThan(0.002),
      reason: '$name: ${finding.elementId}',
    );
  }
  expect(report.total, lessThan(0.016), reason: name);
}

Future<void> landed(ShiftRun run) async {
  for (var i = 0; i < 30; i++) {
    await run.t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
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
  });
  tearDownAll(() => env.dispose());

  for (final screen in <String, Widget>{
    'review doorway': const DetectedActivitiesCard(),
  }.entries) {
    testWidgets('${screen.key} delayed read reserves its content', (t) async {
      phoneSurface(t);
      final repo = _ReadRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final run = ShiftRun(t);
      await t.pumpWidget(
        pilotShot(perfApp(app, screen.value, brightness: Brightness.dark)),
      );
      run.opened();
      await run.frames([0, 150, 200, 216, 466, 2500]);
      await takePilotShot(
        t,
        'review-doorway',
      );
      final spinners = find.byType(CircularProgressIndicator).evaluate().length;
      var announcedBreakdown = false;
      if (screen.key == 'review doorway') {
        final semantics = t.ensureSemantics();
        try {
          await t.pump();
          announcedBreakdown = find
              .bySemanticsLabel(RegExp('Breakdown of your day'))
              .evaluate()
              .isNotEmpty;
        } finally {
          semantics.dispose();
        }
      }
      repo.gate.complete();
      await landed(run);
      check(run, screen.key);
      expect(spinners, 0);
      expect(
        announcedBreakdown,
        isFalse,
        reason: 'unknown counts must not announce zero pending items',
      );
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    });
  }



  // WHY: the Sleep plan has no journal/medication dependency. A stuck journal
  // read must not keep its already available sleep values pending forever.
  testWidgets('Sleep plan settles without reading unrelated journal fields', (
    t,
  ) async {
    phoneSurface(t);
    final repo = _BlockedJournalRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(
      pilotShot(
        perfApp(
          app,
          const WellnessScreen(sleepPlanOnly: true),
          brightness: Brightness.dark,
        ),
      ),
    );
    await t.pump();
    await takePilotShot(t, 'sleep-plan');
    final run = ShiftRun(t);
    await landed(run);
    expect(repo.journalReads, 0);
    expect(
      find.byWidgetPredicate((w) => w is PendingContent && w.pending),
      findsNothing,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'expanded Sleep plan preserves its metric rows while late advice follows them',
    (t) async {
      phoneSurface(t);
      final repo = _LatePlanRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(
        pilotShot(
          perfApp(
            app,
            ListView(
              children: const [
                SettingsAccordion('Your sleep plan', id: 'sleep_plan', initiallyExpanded: true,
                  children: [WellnessScreen(sleepPlanOnly: true)]),
                Text(
                  'Alarm and body clock',
                  key: ValueKey('plan-next-section'),
                ),
              ],
            ),
            brightness: Brightness.dark,
          ),
        ),
      );
      final setup = ShiftRun(t);
      await landed(setup);
      final run = ShiftRun(t)..opened();
      await run.frames([0, 150, 200, 216, 466, 2500]);
      final spinners = find.byType(CircularProgressIndicator).evaluate().length;
      await takePilotShot(t, 'sleep-plan');
      expect(repo.insightsReads, 1);
      final metrics = find.byKey(const ValueKey('sleep-plan-metrics'));
      final beforeMetrics = t.getRect(metrics);
      repo.gate.complete();
      await landed(run);
      expect(t.getRect(metrics), beforeMetrics);
      // Advice is appended after these stable rows. Its explicitly allowed
      // end-of-section growth may move the following accordion.
      expect(repo.insightsReads, 1);
      expect(find.textContaining('Turn in by'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is PendingContent && w.pending),
        findsNothing,
      );
      expect(find.descendant(of: find.byType(SettingsAccordion), matching: find.byType(Scrollable)), findsNothing);
      expect(spinners, 0);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('wearable day has a full pending body before cells arrive', (
    t,
  ) async {
    phoneSurface(t);
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(
      pilotShot(
        perfApp(
          app,
          ValueListenableBuilder<bool>(
            valueListenable: ready,
            builder: (_, loaded, _) =>
                WearableDayView(device: 'Watch', loaded: loaded, hasDay: false),
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    run.opened();
    await run.frames([0, 150, 200, 216, 466, 2500]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await takePilotShot(t, 'wearable-day');
    ready.value = true;
    await run.frames([0, 16, 100]);
    check(run, 'wearable day');
  });

  testWidgets(
    'legacy moment review waits for SQLite without an empty-state flash',
    (t) async {
      phoneSurface(t);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final run = ShiftRun(t);
      await t.pumpWidget(
        pilotShot(
          perfApp(app, const MomentReviewEditor(), brightness: Brightness.dark),
        ),
      );
      run.opened();
      await run.frames([0, 150, 200, 216, 466, 2500]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await takePilotShot(t, 'legacy-review');
      await landed(run);
      expect(find.text('Nothing to follow up on'), findsOneWidget);
      check(run, 'legacy moment review');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    },
  );
}
